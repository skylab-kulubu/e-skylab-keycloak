import java.io.BufferedInputStream;
import java.io.BufferedOutputStream;
import java.io.BufferedReader;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.io.PrintStream;
import java.io.PrintWriter;
import java.io.RandomAccessFile;
import java.lang.reflect.Constructor;
import java.lang.reflect.Field;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.net.URL;
import java.net.URLClassLoader;
import java.nio.charset.Charset;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.IdentityHashMap;
import java.util.List;
import java.util.Set;
import java.util.function.IntConsumer;

/**
 * One JVM for the kcadm reads and the ReconcileJson calls of a reconcile-account-center.sh run.
 *
 * Every kcadm.sh call and every ReconcileJson call used to start a JVM of its own, some two hundred
 * of them for a whole reconciliation (about 8.5 minutes in production, 2026-10-27). The script starts
 * this process once instead, the way kcadm.sh starts its JVM (the same class path, options and
 * kc.lib.dir; config/reconcile-account-center.sh start_session), and this process runs each call the
 * way that JVM's main would have run it:
 *
 * - kcadm: KcAdmMain.main without --v2 is Globals.main(args, new KcAdmCmd(), CMD,
 *   DEFAULT_CONFIG_FILE_STRING). Its set-up (the crypto class loader of kc.lib.dir, CryptoIntegration,
 *   the default config path property) runs once here, as once per JVM there; then each call gets a new
 *   KcAdmCmd and a new command line from Globals.createCommandLine, and the status that main would
 *   have passed to System.exit. Globals' two static options are reset before each call.
 * - json: ReconcileJson.main, in a class loader of its own (the classes and the Jackson of the image
 *   the script compiled it with; the kcadm jar carries another Jackson), with ReconcileJson.exitHook
 *   throwing the status instead of ending the JVM. An exception that would have ended main is printed
 *   as the JVM prints it ("Exception in thread "main" ...", the trace ending at main) and is status 1.
 *
 * Each call gets its own System.in, System.out and System.err, built as the JVM builds them (a
 * 128-byte buffer, autoflush, the stdout.encoding and stderr.encoding charsets); what a call leaves
 * unflushed is dropped, as a JVM drops it at exit. Its arguments are decoded with sun.jnu.encoding, as
 * the launcher decodes argv (this process only runs where that is UTF-8). So a call prints the same
 * bytes, in the same order between stdout and stderr, and ends with the same status as in a JVM of its
 * own. Calls that would not end in main (kcadm's --help, which calls System.exit) are not sent here.
 *
 * Protocol (every path is in the run's private WORK_DIR): at start this process writes "ready" or
 * "unavailable REASON" as one line into the FIFO READY. Then the script writes one line "TOOL DIR" per
 * call into the FIFO REQUESTS: TOOL is kcadm or json, DIR a new directory under the session directory
 * holding "args" (the arguments, each ended by a NUL byte) and, when the call reads stdin, "stdin".
 * Calls run one at a time, in the order their lines arrive. This process writes what the call printed
 * into DIR as numbered segments (000001.o for stdout, 000002.e for stderr, a new one whenever the call
 * switches stream), then one line into the FIFO DIR/done: the exit status, or "failed REASON" when
 * the call could not be run at all. It ends when every writer of REQUESTS is gone.
 */
public final class ReconcileSession {

    private static final String UNAVAILABLE = "unavailable ";
    private static final InputStream NO_STDIN = new InputStream() {
        @Override
        public int read() throws IOException {
            throw new IOException("stdin is not forwarded to this call by the reconciliation session");
        }
    };

    private final Path sessionDirectory;
    private final String command;
    private final Constructor<?> rootCommand;
    private final Method createCommandLine;
    private final Method execute;
    private final Field dumpTrace;
    private final Field help;
    private final ClassLoader kcadmLoader;
    private final ClassLoader jsonLoader;
    private final Method jsonMain;
    private final Charset argumentCharset;
    private final Charset outCharset;
    private final Charset errCharset;

    private ReconcileSession(Path sessionDirectory, String jsonClasspath) throws Exception {
        this.sessionDirectory = sessionDirectory;
        // The launcher decodes argv with sun.jnu.encoding; the script's arguments are UTF-8 bytes.
        String jnu = System.getProperty("sun.jnu.encoding");
        if (jnu == null || !Charset.forName(jnu).equals(StandardCharsets.UTF_8)) {
            throw new IllegalStateException("sun.jnu.encoding is " + jnu + ", not UTF-8");
        }
        argumentCharset = StandardCharsets.UTF_8;
        outCharset = streamCharset("stdout.encoding");
        errCharset = streamCharset("stderr.encoding");

        Class<?> kcAdmMain = Class.forName("org.keycloak.client.admin.cli.KcAdmMain");
        command = (String) kcAdmMain.getField("CMD").get(null);
        String defaultConfigFile = (String) kcAdmMain.getField("DEFAULT_CONFIG_FILE_STRING").get(null);
        rootCommand = Class.forName("org.keycloak.client.admin.cli.commands.KcAdmCmd").getConstructor();
        Class<?> globals = Class.forName("org.keycloak.client.cli.common.Globals");
        createCommandLine = globals.getMethod("createCommandLine",
                Class.forName("org.keycloak.client.cli.common.BaseGlobalOptionsCmd"), String.class, PrintWriter.class);
        dumpTrace = globals.getField("dumpTrace");
        help = globals.getField("help");
        execute = createCommandLine.getReturnType().getMethod("execute", String[].class);
        if (execute.getReturnType() != int.class) {
            throw new IllegalStateException("CommandLine.execute does not return the exit status");
        }
        // Globals.main's set-up, once per JVM there too.
        String libDir = System.getProperty("kc.lib.dir");
        if (libDir == null) {
            throw new IllegalStateException("System property kc.lib.dir needs to be set");
        }
        kcadmLoader = (ClassLoader) Class.forName("org.keycloak.client.cli.util.ClassLoaderUtil")
                .getMethod("resolveClassLoader", String.class).invoke(null, libDir);
        Thread.currentThread().setContextClassLoader(kcadmLoader);
        Class.forName("org.keycloak.common.crypto.CryptoIntegration")
                .getMethod("init", ClassLoader.class).invoke(null, kcadmLoader);
        String configPathKey = (String) Class.forName("org.keycloak.client.cli.common.BaseAuthOptionsCmd")
                .getField("DEFAULT_CONFIG_PATH_STRING_KEY").get(null);
        System.setProperty(configPathKey, defaultConfigFile);

        List<URL> urls = new ArrayList<>();
        for (String entry : jsonClasspath.split(":")) {
            if (!entry.isEmpty()) {
                urls.add(Path.of(entry).toUri().toURL());
            }
        }
        jsonLoader = new URLClassLoader(urls.toArray(URL[]::new), ClassLoader.getPlatformClassLoader());
        Class<?> reconcileJson = Class.forName("ReconcileJson", true, jsonLoader);
        jsonMain = reconcileJson.getMethod("main", String[].class);
        IntConsumer exit = status -> {
            throw new Exit(status);
        };
        reconcileJson.getField("exitHook").set(null, exit);
    }

    public static void main(String[] args) throws IOException {
        if (args.length != 2) {
            System.err.println("usage: ReconcileSession SESSION_DIRECTORY JSON_CLASSPATH");
            System.exit(2);
        }
        Path sessionDirectory = Path.of(args[0]).toAbsolutePath().normalize();
        ReconcileSession session;
        try {
            session = new ReconcileSession(sessionDirectory, args[1]);
        } catch (Exception | LinkageError e) {
            e.printStackTrace();
            signal(sessionDirectory.resolve("ready"), UNAVAILABLE + oneLine(e.toString()));
            return;
        }
        signal(sessionDirectory.resolve("ready"), "ready");
        try (BufferedReader requests = new BufferedReader(new InputStreamReader(
                new FileInputStream(sessionDirectory.resolve("requests").toFile()), StandardCharsets.UTF_8))) {
            String line;
            while ((line = requests.readLine()) != null) {
                session.serve(line);
            }
        }
        // Every writer is gone: the run has ended. A thread kcadm's HTTP client may have left must
        // not keep this JVM.
        System.exit(0);
    }

    private void serve(String line) throws IOException {
        int space = line.indexOf(' ');
        Path directory = space < 0 ? null : Path.of(line.substring(space + 1)).normalize();
        if (directory == null || !sessionDirectory.equals(directory.getParent())) {
            // Nobody waits on a malformed line; the script never writes one.
            System.err.println("ignored a request outside the session directory: " + oneLine(line));
            return;
        }
        String result;
        try {
            result = Integer.toString(call(line.substring(0, space), directory));
        } catch (Exception e) {
            e.printStackTrace();
            result = "failed " + oneLine(e.toString());
        }
        signal(directory.resolve("done"), result);
    }

    private int call(String tool, Path directory) throws Exception {
        if (!tool.equals("kcadm") && !tool.equals("json")) {
            throw new IllegalArgumentException("unknown tool " + tool);
        }
        String[] args = arguments(Files.readAllBytes(directory.resolve("args")));
        Path stdinFile = directory.resolve("stdin");
        InputStream stdin = Files.isRegularFile(stdinFile)
                ? new BufferedInputStream(new FileInputStream(stdinFile.toFile())) : NO_STDIN;
        Segments segments = new Segments(directory);
        // As java.lang.System builds System.out and System.err (newPrintStream).
        PrintStream out = new PrintStream(new BufferedOutputStream(segments.stream('o'), 128), true, outCharset);
        PrintStream err = new PrintStream(new BufferedOutputStream(segments.stream('e'), 128), true, errCharset);
        InputStream savedIn = System.in;
        PrintStream savedOut = System.out;
        PrintStream savedErr = System.err;
        System.setIn(stdin);
        System.setOut(out);
        System.setErr(err);
        try {
            return tool.equals("kcadm") ? kcadm(args) : json(args);
        } finally {
            System.setIn(savedIn);
            System.setOut(savedOut);
            System.setErr(savedErr);
            Thread.currentThread().setContextClassLoader(kcadmLoader);
            if (stdin != NO_STDIN) {
                stdin.close();
            }
            // Not flushed: a JVM drops what is left in these buffers at exit.
            segments.close();
        }
    }

    private int kcadm(String[] args) throws Exception {
        dumpTrace.setBoolean(null, false);
        help.setBoolean(null, false);
        Object commandLine = createCommandLine.invoke(null, rootCommand.newInstance(), command,
                new PrintWriter(System.err, true));
        try {
            return (int) execute.invoke(commandLine, (Object) args);
        } catch (InvocationTargetException e) {
            return uncaught(e.getCause(), "org.keycloak.client.admin.cli.KcAdmMain");
        }
    }

    private int json(String[] args) throws Exception {
        Thread.currentThread().setContextClassLoader(jsonLoader);
        try {
            jsonMain.invoke(null, (Object) args);
            return 0;
        } catch (InvocationTargetException e) {
            if (e.getCause() instanceof Exit exit) {
                return exit.status;
            }
            return uncaught(e.getCause(), "ReconcileJson");
        }
    }

    /** What the JVM does with an exception that ends main (ThreadGroup.uncaughtException), and status 1. */
    private static int uncaught(Throwable thrown, String mainClass) {
        trim(thrown, mainClass, Collections.newSetFromMap(new IdentityHashMap<>()));
        System.err.print("Exception in thread \"" + Thread.currentThread().getName() + "\" ");
        thrown.printStackTrace(System.err);
        return 1;
    }

    /** Drops this process's frames below MAIN_CLASS.main, where the trace of a JVM of its own ends. */
    private static void trim(Throwable thrown, String mainClass, Set<Throwable> seen) {
        if (thrown == null || !seen.add(thrown)) {
            return;
        }
        StackTraceElement[] trace = thrown.getStackTrace();
        for (int i = trace.length - 1; i >= 0; i--) {
            if (trace[i].getClassName().equals(mainClass) && trace[i].getMethodName().equals("main")) {
                thrown.setStackTrace(Arrays.copyOf(trace, i + 1));
                break;
            }
        }
        trim(thrown.getCause(), mainClass, seen);
        for (Throwable suppressed : thrown.getSuppressed()) {
            trim(suppressed, mainClass, seen);
        }
    }

    private String[] arguments(byte[] bytes) {
        List<String> arguments = new ArrayList<>();
        int start = 0;
        for (int i = 0; i < bytes.length; i++) {
            if (bytes[i] == 0) {
                arguments.add(new String(bytes, start, i - start, argumentCharset));
                start = i + 1;
            }
        }
        if (start != bytes.length) {
            throw new IllegalArgumentException("the last argument is not ended by a NUL byte");
        }
        return arguments.toArray(String[]::new);
    }

    private static Charset streamCharset(String property) {
        String encoding = System.getProperty(property);
        return encoding == null ? Charset.defaultCharset() : Charset.forName(encoding, StandardCharsets.UTF_8);
    }

    /** One line into FIFO (or file) PATH. Opened read-write, so that it never waits for a reader. */
    private static void signal(Path path, String line) throws IOException {
        try (RandomAccessFile fifo = new RandomAccessFile(path.toFile(), "rw")) {
            fifo.write((line + "\n").getBytes(StandardCharsets.UTF_8));
        }
    }

    private static String oneLine(String text) {
        return text.replaceAll("[\\r\\n]+", " ");
    }

    /** The status ReconcileJson.main ended with (ReconcileJson.exitHook). */
    private static final class Exit extends RuntimeException {
        private static final long serialVersionUID = 1L;
        private final int status;

        private Exit(int status) {
            super(null, null, false, false);
            this.status = status;
        }
    }

    /** A call's stdout and stderr as numbered files in the order of the writes. */
    private static final class Segments {
        private final Path directory;
        private int count;
        private char current;
        private OutputStream file;

        private Segments(Path directory) {
            this.directory = directory;
        }

        private OutputStream stream(char kind) {
            return new OutputStream() {
                @Override
                public void write(int b) throws IOException {
                    to(kind).write(b);
                }

                @Override
                public void write(byte[] b, int off, int len) throws IOException {
                    if (len > 0) {
                        to(kind).write(b, off, len);
                    }
                }
            };
        }

        private OutputStream to(char kind) throws IOException {
            if (file == null || current != kind) {
                close();
                count++;
                current = kind;
                file = new FileOutputStream(directory.resolve(String.format("%06d.%c", count, kind)).toFile());
            }
            return file;
        }

        private void close() throws IOException {
            if (file != null) {
                file.close();
                file = null;
            }
        }
    }
}
