/* Exact-daemon, message-only Gradle adapter. No build loading, init scripts, daemon
 * creation, shell commands, broad --stop, or emitted authentication material. */
import java.io.*;
import java.nio.file.*;
import java.time.Instant;
import java.util.*;
import com.google.gson.Gson;
import org.gradle.internal.nativeintegration.services.NativeServices;
import org.gradle.internal.service.*;
import org.gradle.internal.service.scopes.BasicGlobalScopeServices;
import org.gradle.internal.logging.services.LoggingServiceRegistry;
import org.gradle.internal.invocation.BuildAction;
import org.gradle.internal.serialize.Serializer;
import org.gradle.internal.serialize.Serializers;
import org.gradle.internal.remote.internal.RemoteConnection;
import org.gradle.internal.remote.internal.inet.TcpOutgoingConnector;
import org.gradle.launcher.daemon.client.*;
import org.gradle.launcher.daemon.registry.*;
import org.gradle.launcher.daemon.protocol.*;
import org.gradle.launcher.daemon.server.api.DaemonState;

class BZGradleDaemon {
  static final String VERSION = "8.14.6";
  static void require(boolean value) { if (!value) throw new IllegalStateException("Owner evidence unavailable or changed"); }
  static void identity(long pid, long startMillis, Path java) throws Exception {
    ProcessHandle p = ProcessHandle.of(pid).orElseThrow();
    require(p.isAlive());
    require(Math.abs(p.info().startInstant().orElseThrow().toEpochMilli() - startMillis) <= 1);
    require(Path.of(p.info().command().orElseThrow()).toRealPath().equals(java.toRealPath()));
  }
  @SuppressWarnings("unchecked")
  static RemoteConnection<Message> readOnlyConnection(ServiceRegistry shared, DaemonInfo daemon) {
    Serializer<BuildAction> serializer = (Serializer<BuildAction>) shared.get(Serializer.class);
    RemoteConnection<Message> connection = new TcpOutgoingConnector().connect(daemon.getAddress(), daemon.getToken())
        .create(Serializers.stateful(DaemonMessageSerializer.create(serializer)));
    // The standard connector removes stale registry entries on connection failure.
    // Inventory must not mutate owner state: use its authenticated transport and
    // serializer directly, never the mutating connector or stale-address callback.
    return connection;
  }
  public static void main(String[] args) {
    // Gradle diagnostics can include daemon context. Only our small projection escapes.
    PrintStream output = System.out;
    System.setOut(new PrintStream(OutputStream.nullOutputStream()));
    System.setErr(new PrintStream(OutputStream.nullOutputStream()));
    Map<String,Object> reply = new LinkedHashMap<>();
    try {
      require(args.length == 7);
      String action = args[0], expectedUID = args[5];
      require(action.equals("inspect") || action.equals("stop-when-idle"));
      long pid = Long.parseLong(args[2]), startMillis = Long.parseLong(args[3]);
      Path home = Path.of(args[1]).toRealPath(), java = Path.of(args[4]).toRealPath();
      require(Files.isRegularFile(home.resolve("daemon/" + VERSION + "/registry.bin"), LinkOption.NOFOLLOW_LINKS));
      identity(pid, startMillis, java);
      require(org.gradle.util.GradleVersion.current().getVersion().equals(VERSION));
      NativeServices.initializeOnClient(home.toFile(), NativeServices.NativeServicesMode.DISABLED);
      ServiceRegistry logging = LoggingServiceRegistry.newEmbeddableLogging();
      try (CloseableServiceRegistry shared = ServiceRegistryBuilder.builder()
          .displayName("BurnZombies owner messages").parent(logging).parent(NativeServices.getInstance())
          .provider(new BasicGlobalScopeServices()).provider(new DaemonClientGlobalServices()).build()) {
        ServiceRegistry services = shared.get(DaemonClientFactory.class).createMessageDaemonServices(logging, home.resolve("daemon").toFile());
        try {
          List<DaemonInfo> matches = services.get(DaemonRegistry.class).getAll().stream()
              .filter(d -> d.getPid() != null && d.getPid() == pid).toList();
          require(matches.size() == 1);
          DaemonInfo daemon = matches.get(0);
          require(UUID.fromString(daemon.getUid()) != null);
          require(daemon.getContext().getJavaHome().toPath().resolve("bin/java").toRealPath().equals(java));
          require(expectedUID.isEmpty() || expectedUID.equals(daemon.getUid()));
          identity(pid, startMillis, java);
          // Native process identity and the registry's authenticated exact endpoint
          // are both checked; registry Idle alone is never treated as a live answer.
          RemoteConnection<Message> connection = readOnlyConnection(shared, daemon);
          require(connection != null);
          Status status;
          try {
            connection.dispatch(new ReportStatus(UUID.randomUUID(), daemon.getToken()));
            connection.flush();
            Message message = connection.receive();
            require(message instanceof Result<?> && ((Result<?>) message).getValue() instanceof Status);
            status = (Status) ((Result<?>) message).getValue();
            connection.dispatch(new Finished());
            connection.flush();
          } finally { connection.stop(); }
          require(status.getPid() == pid && VERSION.equals(status.getVersion()));
          String state = status.getStatus();
          require(state.equals("IDLE") || state.equals("BUSY") || state.equals("CANCELED") || state.equals("STOPPED"));
          reply.put("pid", pid); reply.put("uid", daemon.getUid()); reply.put("version", VERSION);
          reply.put("state", state); reply.put("lastBusyMillis", daemon.getLastBusy().getTime());
          reply.put("javaHome", daemon.getContext().getJavaHome().getCanonicalPath());
          reply.put("accepted", false);
          if (action.equals("stop-when-idle")) {
            require(!expectedUID.isEmpty() && state.equals("IDLE") && daemon.getState() == DaemonState.Idle);
            long expectedBusy = Long.parseLong(args[6]);
            require(daemon.getLastBusy().getTime() == expectedBusy);
            List<DaemonInfo> fresh = services.get(DaemonRegistry.class).getAll().stream()
                .filter(d -> daemon.getUid().equals(d.getUid()) && d.getPid() == pid).toList();
            require(fresh.size() == 1 && fresh.get(0).getState() == DaemonState.Idle
                && fresh.get(0).getLastBusy().getTime() == expectedBusy);
            identity(pid, startMillis, java);
            // If a build races the fresh IDLE check, the OWNER atomically defers
            // its graceful exit until that build completes. Never send Stop.
            services.get(DaemonStopClient.class).gracefulStop(Collections.singletonList(daemon));
            reply.put("accepted", true); // Not an exit or reclaimed-resource receipt.
          }
        } finally { if (services instanceof AutoCloseable) ((AutoCloseable) services).close(); }
      }
      reply.put("ok", true);
    } catch (Throwable failure) {
      reply.clear(); reply.put("ok", false); reply.put("error", "Owner evidence unavailable, unsupported, or changed; preserved.");
      // Code location/type only: exception messages and daemon objects may contain
      // owner context, so never return them (or authentication material).
      reply.put("failureType", failure.getClass().getSimpleName());
      for (StackTraceElement frame : failure.getStackTrace())
        if (frame.getClassName().equals("BZGradleDaemon") && frame.getMethodName().equals("main")) {
          reply.put("boundary", frame.getLineNumber()); break;
        }
    }
    output.println(new Gson().toJson(reply));
    if (!Boolean.TRUE.equals(reply.get("ok"))) System.exit(2);
  }
}
