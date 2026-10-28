#include "CBurn.h"
#include <sys/attr.h>
#include <sys/stat.h>
#include <fts.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define DISK_NODES 4096
#define DISK_HASH 8192
typedef struct {
    FTS *tree;
    char *paths[2];
    int depth, count, done, overflow;
    int table[DISK_HASH];
    bz_disk_node *nodes;
} disk_walk;
struct __attribute__((packed, aligned(4))) private_reply {
    uint32_t length;
    attribute_set_t returned;
    int64_t bytes;
};
static int node_for(disk_walk *w, const char *path) {
    unsigned long h=5381;
    for(const unsigned char *p=(const unsigned char *)path;*p;p++) h=(h*33)^*p;
    unsigned slot=h%DISK_HASH;
    while(w->table[slot]) {
        int i=w->table[slot]-1;
        if(!strcmp(w->nodes[i].path,path)) return i;
        slot=(slot+1)%DISK_HASH;
    }
    if(w->count==DISK_NODES){w->overflow=1;return -1;}
    int i=w->count++;
    strlcpy(w->nodes[i].path,path,sizeof(w->nodes[i].path));
    w->table[slot]=i+1;
    return i;
}
void *bz_disk_open(const char *path, int depth) {
    struct stat s;
    if(!path || strlen(path)>=4096 || lstat(path,&s) || !S_ISDIR(s.st_mode) || (s.st_flags & SF_DATALESS))return NULL;
    disk_walk *w=calloc(1,sizeof(*w));
    if(!w)return NULL;
    w->nodes=calloc(DISK_NODES,sizeof(bz_disk_node));
    w->paths[0]=strdup(path);w->depth=depth<1?1:depth>3?3:depth;
    if(!w->nodes || !w->paths[0]){bz_disk_close(w);return NULL;}
    w->tree=fts_open(w->paths,FTS_PHYSICAL|FTS_XDEV|FTS_NOCHDIR,NULL);
    if(!w->tree){bz_disk_close(w);return NULL;}
    node_for(w,path);
    return w;
}
int bz_disk_step(void *handle,int entries) {
    disk_walk *w=handle;
    if(!w)return -1;
    if(w->done)return 1;
    if(entries<1)entries=1;if(entries>5000)entries=5000;
    for(int k=0;k<entries;k++) {
        errno=0;FTSENT *e=fts_read(w->tree);
        if(!e){if(errno)w->nodes[0].errors++;w->done=1;return 1;}
        if(e->fts_info==FTS_DP) {
            if(e->fts_level<=w->depth){int i=node_for(w,e->fts_path);if(i>=0)w->nodes[i].finished=1;}
            continue;
        }
        if(e->fts_info==FTS_SL || e->fts_info==FTS_SLNONE)continue;
        int indices[4],n=0;
        FTSENT *ancestor=e;
        if(e->fts_info!=FTS_D && e->fts_info!=FTS_DNR)ancestor=e->fts_parent;
        while(ancestor && ancestor->fts_level>=0) {
            if(ancestor->fts_level<=w->depth && n<4 && ancestor->fts_pathlen<4096){
                char path[4096];memcpy(path,e->fts_path,ancestor->fts_pathlen);path[ancestor->fts_pathlen]=0;
                int i=node_for(w,path);if(i>=0)indices[n++]=i;
            }
            ancestor=ancestor->fts_parent;
        }
        if(e->fts_info==FTS_ERR || e->fts_info==FTS_DNR || e->fts_info==FTS_NS) {
            for(int j=0;j<n;j++)w->nodes[indices[j]].errors++;
            continue;
        }
        const struct stat *s=e->fts_statp;
        if(!s)continue;
        if(s->st_flags & SF_DATALESS) {
            for(int j=0;j<n;j++)w->nodes[indices[j]].dataless++;
            if(e->fts_info==FTS_D)fts_set(w->tree,e,FTS_SKIP);
            continue;
        }
        if(e->fts_info!=FTS_F)continue;
        uint64_t private=0;int unknown=0;
        if(s->st_nlink==1) {
            struct attrlist a={0};a.bitmapcount=ATTR_BIT_MAP_COUNT;
            a.commonattr=ATTR_CMN_RETURNED_ATTRS;a.forkattr=ATTR_CMNEXT_PRIVATESIZE;
            struct private_reply r={0};
            if(getattrlist(e->fts_path,&a,&r,sizeof(r),FSOPT_ATTR_CMN_EXTENDED|FSOPT_NOFOLLOW) || r.length<sizeof(r) ||
                !(r.returned.forkattr & ATTR_CMNEXT_PRIVATESIZE) || r.bytes<0)unknown=1;
            else private=(uint64_t)r.bytes;
        }
        for(int j=0;j<n;j++) {
            bz_disk_node *v=&w->nodes[indices[j]];
            v->allocated+=(uint64_t)s->st_blocks*512;v->unshared+=private;v->files++;
            v->unknown+=unknown;v->links+=s->st_nlink>1;
            if(s->st_mtime>v->newest)v->newest=s->st_mtime;
        }
    }
    return 0;
}
int bz_disk_count(void *handle){return handle?((disk_walk *)handle)->count:0;}
int bz_disk_overflow(void *handle){return handle?((disk_walk *)handle)->overflow:0;}
int bz_disk_node_at(void *handle,int index,bz_disk_node *out) {
    disk_walk *w=handle;if(!w || !out || index<0 || index>=w->count)return 0;
    *out=w->nodes[index];return 1;
}
void bz_disk_close(void *handle) {
    disk_walk *w=handle;if(!w)return;
    if(w->tree)fts_close(w->tree);
    free(w->paths[0]);free(w->nodes);free(w);
}
