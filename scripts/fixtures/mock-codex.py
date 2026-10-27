#!/usr/bin/env python3
"""App-server protocol fixture. No provider call or live config access."""
import json,sys
assert sys.argv[1] == 'app-server'
assert 'mcp_servers={}' in sys.argv
assert 'features.hooks=false' in sys.argv
model=''; effort='default'
for arg in sys.argv:
    if arg.startswith('model_reasoning_effort='): effort=json.loads(arg.split('=',1)[1])
def emit(value): print(json.dumps(value),flush=True)
for line in sys.stdin:
    v=json.loads(line);method=v.get('method');params=v.get('params',{})
    if method=='initialize':emit({'id':v['id'],'result':{}})
    elif method=='thread/start':
        assert params['ephemeral'] and params['approvalsReviewer']=='auto_review'
        model=params.get('model','gpt-6.1-sol')
        emit({'id':v['id'],'result':{'thread':{'id':'fixture-thread'},'model':model,'reasoningEffort':effort}})
    elif method=='turn/start':
        emit({'id':v['id'],'result':{'turn':{'id':'fixture-turn'}}})
        usage={'inputTokens':100,'cachedInputTokens':80,'outputTokens':10,'reasoningOutputTokens':5,'totalTokens':110}
        for _ in range(2):emit({'method':'thread/tokenUsage/updated','params':{'threadId':'fixture-thread','turnId':'fixture-turn','tokenUsage':{'total':usage,'last':usage}}})
        emit({'method':'turn/completed','params':{'threadId':'fixture-thread','turn':{'id':'fixture-turn','status':'completed'}}})
