// VoipStream — open VoIP-style audio streams from app_process, no APK.
//
//   CLASSPATH=/data/local/tmp/voipstream.jar app_process / VoipStream <mode> [seconds] [--tone]
//
// modes: record | play | both | mode-comm  (mode-comm = both + MODE_IN_COMMUNICATION)
//        vrec | vrec-ns | vrec-aec | vrec-aec-ns  (record only, source VOICE_RECOGNITION, with the
//        platform NoiseSuppressor / AcousticEchoCanceler attached and enabled)
// seconds: 0 or omitted = run until killed, or until a line "q" arrives on stdin.
// or until the file $VOIPSTREAM_STOP exists. Use voipstream.sh for an orderly
// release on SIGTERM/SIGINT/Ctrl-C.
// See ../README.md.

import android.content.AttributionSource;
import android.content.Context;
import android.content.ContextWrapper;
import android.media.AudioAttributes;
import android.media.AudioFormat;
import android.media.AudioManager;
import android.media.AudioRecord;
import android.media.AudioTrack;
import android.media.MediaRecorder;
import android.media.audiofx.AcousticEchoCanceler;
import android.media.audiofx.NoiseSuppressor;
import android.os.Binder;
import android.os.IBinder;
import android.os.Looper;
import android.os.Process;

import java.lang.reflect.Method;
import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.Locale;

public class VoipStream {
    static final int RATE = 16000;
    static final String PKG = "com.android.shell";
    static final SimpleDateFormat TS = new SimpleDateFormat("yyyy-MM-dd HH:mm:ss.SSS", Locale.US);

    static volatile boolean stop = false;
    static AudioRecord rec;
    static AudioTrack trk;
    static Context ctx;
    static Object audioService;      // IAudioService, for the setMode fallback
    static final IBinder modeCb = new Binder();
    static boolean modeSet = false;
    static int errors = 0;
    static int source = MediaRecorder.AudioSource.VOICE_COMMUNICATION;
    static String sourceName = "VOICE_COMMUNICATION";
    static boolean fxNs = false, fxAec = false;
    static boolean offNs = false, offAec = false;  // --no-ns / --no-aec: disable the auto-attached effect
    static NoiseSuppressor ns;
    static AcousticEchoCanceler aec;

    static synchronized void log(String s) {
        System.out.println(TS.format(new Date()) + " " + s);
        System.out.flush();
    }
    static void err(String s, Throwable t) {
        errors++;
        log("ERROR " + s + (t != null ? ": " + t : ""));
    }

    /** ContextWrapper that reports com.android.shell / our uid to audio + appops. */
    static class ShellContext extends ContextWrapper {
        ShellContext(Context base) { super(base); }
        @Override public String getPackageName() { return PKG; }
        @Override public String getOpPackageName() { return PKG; }
        @Override public String getAttributionTag() { return null; }
        @Override public AttributionSource getAttributionSource() {
            return new AttributionSource.Builder(Process.myUid()).setPackageName(PKG).build();
        }
        @Override public Context getApplicationContext() { return this; }
    }

    static Context makeContext() {
        try {
            if (Looper.getMainLooper() == null) Looper.prepareMainLooper();
        } catch (Throwable t) { /* already prepared */ }
        try {
            Class<?> at = Class.forName("android.app.ActivityThread");
            Object thread = at.getMethod("systemMain").invoke(null);
            Context sys = (Context) at.getMethod("getSystemContext").invoke(thread);
            return new ShellContext(sys);
        } catch (Throwable t) {
            log("WARN no system context (" + t + "); continuing without one");
            return null;
        }
    }

    static void startRecord() {
        int min = AudioRecord.getMinBufferSize(RATE, AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT);
        AudioFormat fmt = new AudioFormat.Builder().setSampleRate(RATE)
                .setChannelMask(AudioFormat.CHANNEL_IN_MONO)
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT).build();
        AudioRecord.Builder b = new AudioRecord.Builder()
                .setAudioSource(source)
                .setAudioFormat(fmt).setBufferSizeInBytes(Math.max(min, 4096) * 2);
        if (ctx != null) b.setContext(ctx);
        rec = b.build();
        if (rec.getState() != AudioRecord.STATE_INITIALIZED)
            throw new IllegalStateException("AudioRecord not initialized");
        int sess = rec.getAudioSessionId();
        if (offNs) {
            ns = NoiseSuppressor.create(sess);
            if (ns == null) err("NoiseSuppressor.create returned null", null);
            else log("NoiseSuppressor disable=" + ns.setEnabled(false) + " enabled=" + ns.getEnabled());
        }
        if (offAec) {
            aec = AcousticEchoCanceler.create(sess);
            if (aec == null) err("AcousticEchoCanceler.create returned null", null);
            else log("AcousticEchoCanceler disable=" + aec.setEnabled(false) + " enabled=" + aec.getEnabled());
        }
        if (fxNs) {
            ns = NoiseSuppressor.create(sess);
            if (ns == null) err("NoiseSuppressor.create returned null (available="
                    + NoiseSuppressor.isAvailable() + ")", null);
            else log("NoiseSuppressor enable=" + ns.setEnabled(true) + " enabled=" + ns.getEnabled());
        }
        if (fxAec) {
            aec = AcousticEchoCanceler.create(sess);
            if (aec == null) err("AcousticEchoCanceler.create returned null (available="
                    + AcousticEchoCanceler.isAvailable() + ")", null);
            else log("AcousticEchoCanceler enable=" + aec.setEnabled(true) + " enabled=" + aec.getEnabled());
        }
        rec.startRecording();
        if (rec.getRecordingState() != AudioRecord.RECORDSTATE_RECORDING)
            throw new IllegalStateException("AudioRecord did not enter RECORDING");
        log("record START source=" + sourceName + " " + RATE + "Hz mono pcm16 session="
                + rec.getAudioSessionId() + " minbuf=" + min);
        Thread t = new Thread(() -> {
            byte[] buf = new byte[640]; // 20 ms
            long total = 0;
            while (!stop) {
                int n = rec.read(buf, 0, buf.length);
                if (n < 0) { err("AudioRecord.read=" + n, null); break; }
                total += n;
            }
            log("record reader exit, " + total + " bytes read");
        }, "rec");
        t.setDaemon(true);
        t.start();
    }

    static void startPlay(boolean tone) {
        int min = AudioTrack.getMinBufferSize(RATE, AudioFormat.CHANNEL_OUT_MONO,
                AudioFormat.ENCODING_PCM_16BIT);
        AudioAttributes attr = new AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build();
        AudioFormat fmt = new AudioFormat.Builder().setSampleRate(RATE)
                .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT).build();
        AudioTrack.Builder b = new AudioTrack.Builder().setAudioAttributes(attr)
                .setAudioFormat(fmt).setBufferSizeInBytes(Math.max(min, 4096) * 2)
                .setTransferMode(AudioTrack.MODE_STREAM);
        if (ctx != null) {
            try { b.setContext(ctx); } catch (Throwable t) { /* API < 34 */ }
        }
        trk = b.build();
        if (trk.getState() != AudioTrack.STATE_INITIALIZED)
            throw new IllegalStateException("AudioTrack not initialized");
        trk.play();
        log("play START usage=VOICE_COMMUNICATION content=SPEECH " + RATE + "Hz mono pcm16 "
                + (tone ? "tone 440Hz @-26dBFS" : "silence") + " session=" + trk.getAudioSessionId()
                + " minbuf=" + min);
        Thread t = new Thread(() -> {
            short[] buf = new short[320]; // 20 ms
            double ph = 0, step = 2 * Math.PI * 440 / RATE;
            long total = 0;
            while (!stop) {
                if (tone) {
                    for (int i = 0; i < buf.length; i++) {
                        buf[i] = (short) (1640 * Math.sin(ph)); // ~-26 dBFS
                        ph += step;
                        if (ph > 2 * Math.PI) ph -= 2 * Math.PI;
                    }
                }
                int n = trk.write(buf, 0, buf.length); // blocking
                if (n < 0) { err("AudioTrack.write=" + n, null); break; }
                total += n;
            }
            log("play writer exit, " + total + " frames written");
        }, "play");
        t.setDaemon(true);
        t.start();
    }

    static int getMode() {
        try {
            if (audioService != null)
                return (Integer) audioService.getClass().getMethod("getMode").invoke(audioService);
        } catch (Throwable t) { /* fall through */ }
        return -99;
    }

    static void setMode(int mode) throws Exception {
        if (audioService == null) {
            Class<?> sm = Class.forName("android.os.ServiceManager");
            IBinder b = (IBinder) sm.getMethod("getService", String.class).invoke(null, "audio");
            Class<?> stub = Class.forName("android.media.IAudioService$Stub");
            audioService = stub.getMethod("asInterface", IBinder.class).invoke(null, b);
        }
        // IAudioService.setMode(int mode, IBinder cb, String callingPackage)
        Method m = audioService.getClass().getMethod("setMode", int.class, IBinder.class, String.class);
        m.invoke(audioService, mode, modeCb, PKG);
    }

    static synchronized void release() {
        if (stop && rec == null && trk == null && !modeSet) return;
        stop = true;
        if (modeSet) {
            try { setMode(AudioManager.MODE_NORMAL); log("mode -> NORMAL (now " + getMode() + ")"); }
            catch (Throwable t) { err("setMode(NORMAL)", unwrap(t)); }
            modeSet = false;
        }
        if (trk != null) {
            try { trk.pause(); trk.flush(); trk.stop(); } catch (Throwable t) { err("AudioTrack.stop", t); }
            trk.release(); trk = null;
            log("play STOP");
        }
        if (rec != null) {
            try { rec.stop(); } catch (Throwable t) { err("AudioRecord.stop", t); }
            if (ns != null) { ns.release(); ns = null; }
            if (aec != null) { aec.release(); aec = null; }
            rec.release(); rec = null;
            log("record STOP");
        }
    }

    static Throwable unwrap(Throwable t) {
        while (t instanceof java.lang.reflect.InvocationTargetException && t.getCause() != null)
            t = t.getCause();
        return t;
    }

    /**
     * ART has no sun.misc.Signal and does not run shutdown hooks on SIGTERM/SIGINT:
     * the process just dies (audioserver then tears the streams down on binder death).
     * For an orderly release, a line "q" on stdin, or the file named by $VOIPSTREAM_STOP
     * appearing, stops the run; voipstream.sh turns SIGTERM/SIGINT/HUP into the latter
     * (shell may not mkfifo in /data/local/tmp under SELinux). The shutdown hook covers
     * System.exit paths.
     */
    static void installStopHooks() {
        Runtime.getRuntime().addShutdownHook(new Thread(VoipStream::release));
        Thread t = new Thread(() -> {
            try {
                java.io.BufferedReader r = new java.io.BufferedReader(
                        new java.io.InputStreamReader(System.in));
                String line;
                while ((line = r.readLine()) != null) {
                    if (line.trim().equals("q")) { log("stop requested"); stop = true; return; }
                }
            } catch (Throwable e) { /* no stdin: ignore, run on */ }
        }, "stdin");
        t.setDaemon(true);
        t.start();
    }

    static void usage() {
        System.err.println("usage: app_process / VoipStream record|play|both|mode-comm|vrec|vrec-ns|vrec-aec|vrec-aec-ns [seconds] [--tone] [--no-ns] [--no-aec]");
        System.exit(2);
    }

    public static void main(String[] args) throws Exception {
        String mode = null; int secs = 0; boolean tone = false;
        for (String a : args) {
            if (a.equals("--tone")) tone = true;
            else if (a.equals("--no-ns")) offNs = true;
            else if (a.equals("--no-aec")) offAec = true;
            else if (mode == null) mode = a;
            else secs = Integer.parseInt(a);
        }
        if (mode == null) usage();
        if (mode.startsWith("vrec")) {
            source = MediaRecorder.AudioSource.VOICE_RECOGNITION;
            sourceName = "VOICE_RECOGNITION";
            if (mode.equals("vrec-ns")) fxNs = true;
            else if (mode.equals("vrec-aec-ns")) { fxNs = true; fxAec = true; }
            else if (mode.equals("vrec-aec")) fxAec = true;
            else if (!mode.equals("vrec")) usage();
        }
        boolean doRec = mode.equals("record") || mode.equals("both") || mode.equals("mode-comm")
                || mode.startsWith("vrec");
        boolean doPlay = mode.equals("play") || mode.equals("both") || mode.equals("mode-comm");
        boolean doMode = mode.equals("mode-comm");
        if (!doRec && !doPlay) usage();

        log("VoipStream mode=" + mode + " seconds=" + (secs > 0 ? secs : "until killed")
                + " uid=" + Process.myUid() + " pid=" + Process.myPid());
        installStopHooks();
        ctx = makeContext();

        try {
            if (doMode) {
                try {
                    setMode(AudioManager.MODE_IN_COMMUNICATION);
                    modeSet = true;
                    log("mode -> IN_COMMUNICATION (now " + getMode() + ")");
                } catch (Throwable t) { err("setMode(IN_COMMUNICATION)", unwrap(t)); }
            }
            if (doRec) {
                try { startRecord(); } catch (Throwable t) { err("record start", t); }
            }
            if (doPlay) {
                try { startPlay(tone); } catch (Throwable t) { err("play start", t); }
            }
            if (rec == null && trk == null) { release(); log("nothing started, exit 1"); System.exit(1); }

            long end = secs > 0 ? System.currentTimeMillis() + secs * 1000L : Long.MAX_VALUE;
            int lastMode = getMode();
            String sp = System.getenv("VOIPSTREAM_STOP");
            java.io.File stopFile = sp != null && !sp.isEmpty() ? new java.io.File(sp) : null;
            while (!stop && System.currentTimeMillis() < end) {
                Thread.sleep(200);
                if (stopFile != null && stopFile.exists()) { log("stop requested (signal)"); stop = true; }
                if (doMode) {
                    int m = getMode();
                    if (m != lastMode) { log("audio mode changed " + lastMode + " -> " + m); lastMode = m; }
                }
            }
        } finally {
            release();
        }
        log("done, errors=" + errors);
        System.exit(errors == 0 ? 0 : 1);
    }
}
