package jp.namecard.nfctest;

import android.app.Activity;
import android.content.Intent;
import android.nfc.NfcAdapter;
import android.nfc.Tag;
import android.nfc.TagLostException;
import android.nfc.tech.NfcV;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.provider.OpenableColumns;
import android.view.View;
import android.widget.Button;
import android.widget.ArrayAdapter;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.Spinner;
import android.widget.TextView;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.Arrays;
import java.util.Locale;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.zip.CRC32;

public final class MainActivity extends Activity {
    private static final int PICK_IMAGE = 1;
    private static final int IMAGE_SIZE = 4736;
    private static final int MODE_NONE = 0;
    private static final int MODE_STATUS = 1;
    private static final int MODE_PATTERN = 2;
    private static final int MODE_IMAGE = 3;
    private static final int MODE_PATTERN_SEQUENCE = 4;
    private static final int PATTERN_COUNT = 10;
    private static final String[] PATTERN_NAMES = {
        "1. チェック柄", "2. NFC OK（文字）", "3. 全面黒", "4. 全面白",
        "5. 長辺方向の縞", "6. 短辺方向の縞", "7. グリッド",
        "8. 斜線", "9. ターゲット", "10. TEST 10（文字）"
    };
    private static final long BOOT_QUIET_MS = 1500L;
    private static final long CHARGE_QUIET_MS = 1500L;
    private static final long FRAME_RECHARGE_MS = 500L;
    private final Handler ui = new Handler(Looper.getMainLooper());
    private final AtomicBoolean running = new AtomicBoolean(false);
    private NfcAdapter adapter;
    private TextView status;
    private Button checkStatus;
    private Button pattern;
    private Button patternSequence;
    private Button choose;
    private Spinner patternChoice;
    private byte[] image;
    private volatile ImageTransferSession imageTransferSession;
    private volatile int pendingMode = MODE_NONE;
    private volatile int selectedPatternId = 1;
    private volatile int continuousNextPattern = 1;

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        adapter = NfcAdapter.getDefaultAdapter(this);

        LinearLayout content = new LinearLayout(this);
        content.setOrientation(LinearLayout.VERTICAL);
        content.setPadding(32, 40, 32, 40);
        checkStatus = new Button(this);
        checkStatus.setText("1. 接続・STATUS確認（表示更新なし）");
        checkStatus.setOnClickListener(this::selectStatusCheck);
        content.addView(checkStatus);
        TextView patternLabel = new TextView(this);
        patternLabel.setText("内蔵パターン（画像転送なし）");
        content.addView(patternLabel);
        patternChoice = new Spinner(this);
        patternChoice.setAdapter(new ArrayAdapter<>(this,
                android.R.layout.simple_spinner_dropdown_item, PATTERN_NAMES));
        content.addView(patternChoice);
        pattern = new Button(this);
        pattern.setText("2. 選択パターンを書き換え（1 byte）");
        pattern.setOnClickListener(this::selectPattern);
        content.addView(pattern);
        patternSequence = new Button(this);
        patternSequence.setText("3. 10種類を連続書き換え");
        patternSequence.setOnClickListener(this::selectPatternSequence);
        content.addView(patternSequence);
        choose = new Button(this);
        choose.setText("4. 4736-byte画像を選択・分割転送");
        choose.setOnClickListener(this::chooseImage);
        content.addView(choose);
        status = new TextView(this);
        status.setTextSize(16);
        status.setText("試験を選んでから名刺へタッチしてください。\n"
                + "FWが前回表示を保持し、差分Partial更新します。\n"
                + "画像形式: 1=白、MSB first、SSD1680 RAM順。\n");
        content.addView(status);
        ScrollView scroll = new ScrollView(this);
        scroll.addView(content);
        setContentView(scroll);
    }

    private void selectStatusCheck(View ignored) {
        pendingMode = MODE_STATUS;
        log("STATUS確認を選択。名刺にタッチしてください。\n");
    }

    private void selectPattern(View ignored) {
        selectedPatternId = patternChoice.getSelectedItemPosition() + 1;
        pendingMode = MODE_PATTERN;
        log(PATTERN_NAMES[selectedPatternId - 1]
                + " を選択。名刺にタッチして動かさないでください。\n");
    }

    private void selectPatternSequence(View ignored) {
        continuousNextPattern = 1;
        pendingMode = MODE_PATTERN_SEQUENCE;
        log("10種類の連続書き換えを選択。完了まで同じ位置に固定してください。\n");
    }

    private void chooseImage(View ignored) {
        Intent intent = new Intent(Intent.ACTION_OPEN_DOCUMENT);
        intent.setType("application/octet-stream");
        intent.addCategory(Intent.CATEGORY_OPENABLE);
        startActivityForResult(intent, PICK_IMAGE);
    }

    @Override protected void onActivityResult(int request, int result, Intent data) {
        super.onActivityResult(request, result, data);
        if (request != PICK_IMAGE || result != RESULT_OK || data == null) return;
        try (InputStream input = getContentResolver().openInputStream(data.getData())) {
            image = readAll(input);
            if (image.length != IMAGE_SIZE) {
                image = null;
                throw new IllegalArgumentException("画像は正確に4736バイト必要です");
            }
            imageTransferSession = null;
            pendingMode = MODE_IMAGE;
            String name = "image.bin";
            try (android.database.Cursor cursor = getContentResolver().query(
                    data.getData(), null, null, null, null)) {
                if (cursor != null && cursor.moveToFirst()) {
                    int index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME);
                    if (index >= 0) name = cursor.getString(index);
                }
            }
            log(name + " を読込済み。名刺にタッチして動かさないでください。\n");
        } catch (Exception error) {
            log("画像読込エラー: " + error.getMessage() + "\n");
        }
    }

    @Override protected void onResume() {
        super.onResume();
        enableReaderMode();
    }

    @Override protected void onPause() {
        if (adapter != null) adapter.disableReaderMode(this);
        super.onPause();
    }

    private void enableReaderMode() {
        if (adapter == null || !adapter.isEnabled()) return;
        Bundle options = new Bundle();
        options.putInt(NfcAdapter.EXTRA_READER_PRESENCE_CHECK_DELAY, 5000);
        adapter.enableReaderMode(this, this::handleTag,
                NfcAdapter.FLAG_READER_NFC_V |
                NfcAdapter.FLAG_READER_SKIP_NDEF_CHECK,
                options);
    }

    private void restartReaderModeAfterLoss() {
        ui.post(() -> {
            if (adapter == null || isFinishing() || isDestroyed()) return;
            adapter.disableReaderMode(this);
            /* Android 17 can retain the stale Tag object after a transceive
               TagLost while the long presence-check delay is active. Briefly
               cycling Reader Mode forces a fresh inventory callback without
               shortening the quiet interval used during EPD refresh. */
            ui.postDelayed(() -> {
                if (isFinishing() || isDestroyed()) return;
                enableReaderMode();
                log("NFC探索を再開しました。そのまま位置を合わせてください。\n");
            }, 200L);
        });
    }

    private void handleTag(Tag tag) {
        final int mode = pendingMode;
        if (tag == null) return;
        if (mode == MODE_NONE) {
            log("NFC-Vタグを検出しました。先に試験ボタンを選んでください。\n");
            return;
        }
        if (((mode == MODE_IMAGE) && (image == null)) ||
            !running.compareAndSet(false, true)) return;
        log("NFC-V検出 UID=" + hex(tag.getId())
                + (mode == MODE_STATUS
                    ? "。MCU起動を待ちます。\n"
                    : "。MCU起動・VRES充電を待ちます。\n"));
        byte[] transferImage = mode == MODE_IMAGE
                ? Arrays.copyOf(image, image.length)
                : null;
        final int patternId = selectedPatternId;
        setControlsEnabled(false);
        new Thread(() -> transfer(tag, mode, transferImage, patternId),
                   "namecard-ftm").start();
    }

    private void transfer(Tag tag, int mode, byte[] transferImage, int patternId) {
        NfcV nfc = NfcV.get(tag);
        String stage = "NFC接続";
        int transferredBytes = 0;
        ImageTransferSession activeImageSession = null;
        try {
            if (nfc == null) throw new IllegalStateException("NFC-Vタグではありません");
            nfc.connect();
            St25Mailbox mailbox = new St25Mailbox(nfc, tag.getId());
            Thread.sleep(BOOT_QUIET_MS);
            stage = "Mailbox有効化";
            mailbox.enable();
            if (mode == MODE_IMAGE) {
                synchronized (this) {
                    if ((imageTransferSession == null) ||
                        !Arrays.equals(imageTransferSession.image, transferImage)) {
                        imageTransferSession = new ImageTransferSession(transferImage);
                    }
                    activeImageSession = imageTransferSession;
                }
                transferredBytes = activeImageSession.offset;
            }
            int transferId = activeImageSession != null
                    ? activeImageSession.transferId
                    : (int)(System.currentTimeMillis() & 0xFFFF);

            if (mode == MODE_STATUS) {
                stage = "STATUS";
                Ack ack = mailbox.exchange(Protocol.frame(4, transferId, 0, 0, new byte[0]));
                ack.requireSuccess();
                log(String.format(Locale.US,
                        "STATUS OK: state=%d VDD=%dmV min=%dmV error=%d\n",
                        ack.state, ack.vddMv, ack.minimumVddMv, ack.error));
                return;
            }

            if (mode == MODE_PATTERN) {
                stage = "PATTERN " + patternId;
                runPatternUpdate(mailbox, patternId);
                return;
            }

            if (mode == MODE_PATTERN_SEQUENCE) {
                while (continuousNextPattern <= PATTERN_COUNT) {
                    int next = continuousNextPattern;
                    stage = "PATTERN連続 " + next + "/" + PATTERN_COUNT;
                    log(String.format(Locale.US, "連続試験 %d/%d: %s\n",
                            next, PATTERN_COUNT, PATTERN_NAMES[next - 1]));
                    runPatternUpdate(mailbox, next);
                    continuousNextPattern = next + 1;
                }
                log("10種類の連続書き換えが完了しました。\n");
                continuousNextPattern = 1;
                return;
            }

            int maxChunk = Math.min(240, nfc.getMaxTransceiveLength() - 28);
            if (maxChunk < 32) throw new IllegalStateException("NFC転送長が不足しています");
            activeImageSession.maxChunk = maxChunk;
            log(String.format(Locale.US, "接続: maxTx=%d, DATA payload=%d\n",
                    nfc.getMaxTransceiveLength(), maxChunk));

            if (activeImageSession.started) {
                log(String.format(Locale.US,
                        "前回の進捗から再開: %d / %d bytes（seq=%d）\n",
                        activeImageSession.offset, IMAGE_SIZE,
                        activeImageSession.sequence));
            }

            while (!activeImageSession.committed) {
                    if (!activeImageSession.started) {
                        stage = "START送信";
                        Ack ack = mailbox.exchange(Protocol.frame(
                                1, transferId, 0, 0, activeImageSession.metadata));
                        ack.requireSuccess();
                        activeImageSession.started = true;
                        activeImageSession.sequence = ack.expectedSequence;
                        activeImageSession.offset = ack.expectedOffset;
                        transferredBytes = activeImageSession.offset;
                        log("START ACK。最初のDATA前に " + FRAME_RECHARGE_MS
                                + "ms蓄電します。\n");
                        Thread.sleep(FRAME_RECHARGE_MS);
                        continue;
                    }

                    if (activeImageSession.offset < transferImage.length) {
                        int offset = activeImageSession.offset;
                        int end = Math.min(offset + maxChunk, transferImage.length);
                        byte[] chunk = Arrays.copyOfRange(transferImage, offset, end);
                        stage = "DATA " + offset + "–" + end + " bytes";
                        Ack ack = mailbox.exchange(Protocol.frame(
                                2, transferId, activeImageSession.sequence, offset, chunk));

                        if (ack.error == 7) {
                            log("MCUが再起動したためSTARTから自動再開します。\n");
                            activeImageSession.resetProgress();
                            transferredBytes = 0;
                            continue;
                        }
                        if ((ack.error == 8 || ack.error == 9) &&
                            (ack.expectedOffset >= 0) &&
                            (ack.expectedOffset <= IMAGE_SIZE)) {
                            activeImageSession.sequence = ack.expectedSequence;
                            activeImageSession.offset = ack.expectedOffset;
                            transferredBytes = activeImageSession.offset;
                            log(String.format(Locale.US,
                                    "FWの期待位置へ再同期: %d / %d bytes（seq=%d）\n",
                                    transferredBytes, IMAGE_SIZE,
                                    activeImageSession.sequence));
                            continue;
                        }

                        ack.requireSuccess();
                        activeImageSession.sequence = ack.expectedSequence;
                        activeImageSession.offset = ack.expectedOffset;
                        transferredBytes = activeImageSession.offset;
                        log(String.format(Locale.US, "%d / %d bytes, VDD=%dmV\n",
                                transferredBytes, IMAGE_SIZE, ack.vddMv));
                        if (activeImageSession.offset < transferImage.length) {
                            Thread.sleep(FRAME_RECHARGE_MS);
                        }
                        continue;
                    }

                    stage = "COMMIT送信";
                    Ack ack = mailbox.exchange(Protocol.frame(
                            3, transferId, activeImageSession.sequence,
                            IMAGE_SIZE, new byte[0]));
                    if (ack.error == 7) {
                        log("COMMIT前にMCUが再起動したためSTARTからやり直します。\n");
                        activeImageSession.resetProgress();
                        transferredBytes = 0;
                        continue;
                    }
                    ack.requireSuccess();
                    activeImageSession.sequence = ack.expectedSequence;
                    activeImageSession.offset = ack.expectedOffset;
                    activeImageSession.committed = true;
                }

            int sequence = activeImageSession.sequence;
            int imageOffset = IMAGE_SIZE;

            log("VRES充電のためRF通信を1.5秒停止します。位置を固定してください。\n");
            Thread.sleep(CHARGE_QUIET_MS);
            Ack ack;
            do {
                stage = "充電STATUS確認";
                ack = mailbox.exchange(Protocol.frame(4, transferId, sequence, imageOffset, new byte[0]));
                ack.requireSuccess();
                log(String.format(Locale.US, "充電: state=%d VDD=%dmV min=%dmV\n",
                        ack.state, ack.vddMv, ack.minimumVddMv));
                if ((mode == MODE_IMAGE) && (ack.state == 1)) {
                    activeImageSession.resetProgress();
                    throw new IllegalStateException(
                            "MCUが電源断しました。再タッチするとSTARTから再開します");
                }
                if (ack.state == 6) {
                    log("更新はすでに完了しています。\n");
                    imageTransferSession = null;
                    return;
                }
                if (ack.state != 3) Thread.sleep(1000);
            } while (ack.state != 3);

            stage = "EXECUTE送信";
            ack = mailbox.exchange(Protocol.frame(5, transferId, sequence, imageOffset, new byte[0]));
            ack.requireSuccess();
            int quiet = Math.max(2000, ack.quietMs);
            log("EXECUTE ACK受信。RF通信を " + quiet + "ms 停止します。動かさないでください。\n");
            Thread.sleep(quiet + 250L); // RF field remains present while no transceive is issued.
            stage = "更新完了STATUS確認";
            Ack complete = mailbox.exchange(Protocol.frame(4, transferId, sequence + 1,
                                                            imageOffset, new byte[0]));
            complete.requireSuccess();
            if (complete.state != 6) {
                throw new IllegalStateException("更新後state=" + complete.state + " error=" + complete.error);
            }
            log(String.format(Locale.US, "完了: VDD=%dmV, 更新中min=%dmV\n",
                    complete.vddMv, complete.minimumVddMv));
            if (mode == MODE_IMAGE) imageTransferSession = null;
        } catch (TagLostException error) {
            log("タグを見失いました: " + stage
                    + (mode == MODE_IMAGE
                        ? "（" + transferredBytes + " / " + IMAGE_SIZE + " bytes）"
                        : "")
                    + "\n進捗を保持しました。位置を合わせてそのまま再タッチしてください。\n");
            restartReaderModeAfterLoss();
        } catch (Exception error) {
            log("失敗: " + stage + ": " + error.getMessage()
                    + (mode == MODE_IMAGE
                        ? "\n画像の進捗を保持しました。そのまま再タッチしてください。\n"
                        : mode == MODE_PATTERN_SEQUENCE
                        ? "\n次のパターン番号を保持しました。位置を合わせてそのまま再タッチしてください。\n"
                        : "\nもう一度試験を選んでタッチしてください。\n"));
            if (mode == MODE_PATTERN_SEQUENCE) restartReaderModeAfterLoss();
        } finally {
            try { if (nfc != null) nfc.close(); } catch (Exception ignored) { }
            running.set(false);
            setControlsEnabled(true);
        }
    }

    private void runPatternUpdate(St25Mailbox mailbox, int patternId) throws Exception {
        int transferId = (int)((System.currentTimeMillis() + patternId) & 0xFFFF);
        Ack ack = mailbox.exchange(Protocol.frame(
                6, transferId, 0, 0, new byte[] {(byte)patternId}));
        ack.requireSuccess();
        log(String.format(Locale.US,
                "PATTERN %d ACK: VDD=%dmV。VRESを充電します。\n", patternId, ack.vddMv));

        Thread.sleep(CHARGE_QUIET_MS);
        do {
            ack = mailbox.exchange(Protocol.frame(
                    4, transferId, 1, IMAGE_SIZE, new byte[0]));
            ack.requireSuccess();
            log(String.format(Locale.US, "充電: state=%d VDD=%dmV min=%dmV\n",
                    ack.state, ack.vddMv, ack.minimumVddMv));
            if (ack.state != 3) Thread.sleep(1000L);
        } while (ack.state != 3);

        ack = mailbox.exchange(Protocol.frame(
                5, transferId, 1, IMAGE_SIZE, new byte[0]));
        ack.requireSuccess();
        int quiet = Math.max(2000, ack.quietMs);
        log("EXECUTE ACK。" + quiet + "ms、RF通信を停止します。\n");
        Thread.sleep(quiet + 250L);

        Ack complete = mailbox.exchange(Protocol.frame(
                4, transferId, 2, IMAGE_SIZE, new byte[0]));
        complete.requireSuccess();
        if (complete.state != 6) {
            throw new IllegalStateException(
                    "PATTERN " + patternId + " 更新後state=" + complete.state);
        }
        log(String.format(Locale.US,
                "PATTERN %d 完了: VDD=%dmV, 更新中min=%dmV\n",
                patternId, complete.vddMv, complete.minimumVddMv));
    }

    private void setControlsEnabled(boolean enabled) {
        ui.post(() -> {
            checkStatus.setEnabled(enabled);
            patternChoice.setEnabled(enabled);
            pattern.setEnabled(enabled);
            patternSequence.setEnabled(enabled);
            choose.setEnabled(enabled);
        });
    }

    private static byte[] readAll(InputStream input) throws Exception {
        if (input == null) throw new IllegalArgumentException("ファイルを開けません");
        ByteArrayOutputStream output = new ByteArrayOutputStream();
        byte[] buffer = new byte[4096];
        int count;
        while ((count = input.read(buffer)) >= 0) output.write(buffer, 0, count);
        return output.toByteArray();
    }

    private static String hex(byte[] value) {
        StringBuilder output = new StringBuilder(value.length * 2);
        for (byte item : value) output.append(String.format(Locale.US, "%02X", item & 0xFF));
        return output.toString();
    }

    private void log(String message) {
        ui.post(() -> status.append(message));
    }

    private static final class ImageTransferSession {
        final byte[] image;
        final byte[] metadata;
        final int transferId;
        int maxChunk;
        int sequence;
        int offset;
        boolean started;
        boolean committed;

        ImageTransferSession(byte[] source) {
            image = Arrays.copyOf(source, source.length);
            transferId = (int)(System.currentTimeMillis() & 0xFFFF);
            CRC32 crc = new CRC32();
            crc.update(image);
            metadata = ByteBuffer.allocate(16).order(ByteOrder.LITTLE_ENDIAN)
                    .putShort((short)296)
                    .putShort((short)128)
                    .putShort((short)IMAGE_SIZE)
                    .put((byte)1)
                    .put((byte)1)
                    .putInt((int)crc.getValue())
                    .putInt(0)
                    .array();
        }

        void resetProgress() {
            sequence = 0;
            offset = 0;
            started = false;
            committed = false;
        }
    }

    private static final class St25Mailbox {
        private static final int FLAGS = 0x22; // addressed + high data rate
        private static final int MFG_ST = 0x02;
        private static final int ACK_FRAME_SIZE = 32;
        private static final long ACK_SETTLE_MS = 80L;
        private static final long ACK_POLL_MS = 25L;
        private final NfcV nfc;
        private final byte[] uid;

        St25Mailbox(NfcV nfc, byte[] uid) { this.nfc = nfc; this.uid = uid; }

        void enable() throws Exception {
            final int control;
            try {
                control = readControl();
            } catch (St25CommandException error) {
                throw explainMailboxError(error);
            }
            if ((control & 0x01) != 0) return;
            try {
                command(0xAE, new byte[] {0x0D, 0x01});
            } catch (St25CommandException error) {
                throw explainMailboxError(error);
            }
            if ((readControl() & 0x01) == 0) {
                throw new IllegalStateException("MB_ENを書き込めませんでした");
            }
        }

        private static Exception explainMailboxError(St25CommandException error) {
            if (error.errorCode == 0x10) {
                return new IllegalStateException(
                        "Mailbox register unavailable。ST25公式アプリで静的MB_MODE=1を設定してください",
                        error);
            }
            return error;
        }

        Ack exchange(byte[] message) throws Exception {
            waitMailboxFree(1000);
            byte[] write = new byte[1 + message.length];
            write[0] = (byte)(message.length - 1);
            System.arraycopy(message, 0, write, 1, message.length);
            command(0xAA, write);

            /* Give the MCU time to consume the RF message and publish its ACK.
               This avoids hammering MB_CTRL_Dyn while EH and I2C are active. */
            Thread.sleep(ACK_SETTLE_MS);
            long deadline = System.currentTimeMillis() + 1500;
            while (System.currentTimeMillis() < deadline) {
                int control = readControl();
                if ((control & 0x02) != 0) return Ack.decode(readHostMessage());
                Thread.sleep(ACK_POLL_MS);
            }
            String diagnostic = "";
            try {
                int mailboxControl = readControl();
                int energyControl = readDynamic(0x02);
                diagnostic = String.format(Locale.US,
                        " MB_CTRL=%02X EH_CTRL=%02X", mailboxControl, energyControl);
            } catch (Exception ignored) {
                diagnostic = " (dynamic register diagnostic failed)";
            }
            throw new IllegalStateException("MCU ACK timeout;" + diagnostic);
        }

        private void waitMailboxFree(long timeoutMs) throws Exception {
            long deadline = System.currentTimeMillis() + timeoutMs;
            while (System.currentTimeMillis() < deadline) {
                int control = readControl();
                if ((control & 0x06) == 0) return;
                if ((control & 0x02) != 0) readHostMessage(); // discard stale ACK completely
                Thread.sleep(10);
            }
            throw new IllegalStateException("mailbox busy");
        }

        private int readControl() throws Exception { return readDynamic(0x0D); }

        private int readDynamic(int address) throws Exception {
            return command(0xAD, new byte[] {(byte)address})[0] & 0xFF;
        }

        private byte[] readHostMessage() throws Exception {
            /* Namecard ACK is fixed at 16-byte header + 16-byte payload. Reading
               that known length directly saves one RF Read Message Length
               transaction for every image chunk. */
            byte[] answer = command(0xAC,
                    new byte[] {0, (byte)(ACK_FRAME_SIZE - 1)});
            if (answer.length != ACK_FRAME_SIZE) {
                throw new IllegalStateException("ACK length mismatch: " + answer.length);
            }
            return answer;
        }

        private byte[] command(int code, byte[] parameters) throws Exception {
            byte[] request = new byte[3 + uid.length + parameters.length];
            request[0] = (byte)FLAGS;
            request[1] = (byte)code;
            request[2] = (byte)MFG_ST;
            System.arraycopy(uid, 0, request, 3, uid.length);
            System.arraycopy(parameters, 0, request, 3 + uid.length, parameters.length);
            if (request.length > nfc.getMaxTransceiveLength()) {
                throw new IllegalStateException("phone maxTransceiveLength exceeded: " + request.length);
            }
            byte[] response = nfc.transceive(request);
            if (response.length == 0) throw new IllegalStateException("empty NFC response");
            if ((response[0] & 0x01) != 0) {
                int error = response.length > 1 ? response[1] & 0xFF : -1;
                throw new St25CommandException(code, error);
            }
            return Arrays.copyOfRange(response, 1, response.length);
        }
    }

    private static final class St25CommandException extends Exception {
        final int commandCode;
        final int errorCode;

        St25CommandException(int commandCode, int errorCode) {
            super(String.format(Locale.US, "ST25 command %02X error %02X",
                                commandCode, errorCode));
            this.commandCode = commandCode;
            this.errorCode = errorCode;
        }
    }

    private static final class Protocol {
        static byte[] frame(int type, int transferId, int sequence, int offset, byte[] payload) {
            ByteBuffer value = ByteBuffer.allocate(16 + payload.length).order(ByteOrder.LITTLE_ENDIAN);
            value.put((byte)'N').put((byte)'C').put((byte)1).put((byte)type);
            value.putShort((short)transferId).putShort((short)sequence).putShort((short)offset);
            value.putShort((short)payload.length).putShort((short)0).putShort((short)crc16(payload));
            value.put(payload);
            byte[] raw = value.array();
            byte[] headerCrcInput = new byte[14];
            System.arraycopy(raw, 0, headerCrcInput, 0, 12);
            System.arraycopy(raw, 14, headerCrcInput, 12, 2);
            ByteBuffer.wrap(raw).order(ByteOrder.LITTLE_ENDIAN).putShort(12, (short)crc16(headerCrcInput));
            return raw;
        }

        static int crc16(byte[] data) {
            int crc = 0xFFFF;
            for (byte item : data) {
                crc ^= (item & 0xFF) << 8;
                for (int bit = 0; bit < 8; bit++)
                    crc = (crc & 0x8000) != 0 ? ((crc << 1) ^ 0x1021) & 0xFFFF : (crc << 1) & 0xFFFF;
            }
            return crc;
        }
    }

    private static final class Ack {
        final int code, state, error, expectedSequence, expectedOffset;
        final int vddMv, minimumVddMv, quietMs;
        Ack(int code, int state, int error, int expectedSequence, int expectedOffset,
            int vddMv, int minimumVddMv, int quietMs) {
            this.code = code; this.state = state; this.error = error;
            this.expectedSequence = expectedSequence;
            this.expectedOffset = expectedOffset;
            this.vddMv = vddMv; this.minimumVddMv = minimumVddMv; this.quietMs = quietMs;
        }
        static Ack decode(byte[] raw) {
            if (raw.length < 32 || raw[0] != 'N' || raw[1] != 'C')
                throw new IllegalStateException("invalid ACK frame");
            byte[] copy = Arrays.copyOf(raw, raw.length);
            int storedHeaderCrc = u16(copy, 12);
            copy[12] = copy[13] = 0;
            byte[] check = new byte[14];
            System.arraycopy(copy, 0, check, 0, 12);
            System.arraycopy(copy, 14, check, 12, 2);
            if (Protocol.crc16(check) != storedHeaderCrc ||
                Protocol.crc16(Arrays.copyOfRange(raw, 16, raw.length)) != u16(raw, 14))
                throw new IllegalStateException("ACK CRC mismatch");
            return new Ack(raw[17] & 0xFF, raw[18] & 0xFF, raw[19] & 0xFF,
                           u16(raw, 20), u16(raw, 22),
                           u16(raw, 24), u16(raw, 26), u16(raw, 28));
        }
        void requireSuccess() {
            if (code == 0x80 || error != 0) {
                throw new IllegalStateException("FW error=" + error + " (" + errorName(error) + ")");
            }
        }
        private static String errorName(int error) {
            switch (error) {
                case 14: return "VDD charge timeout";
                case 15: return "VDD droop";
                case 16: return "EPD BUSY timeout";
                case 17: return "EPD I/O";
                case 18: return "STM32-ST25 I2C/Mailbox I/O";
                case 19: return "EXECUTE ACK timeout";
                case 20: return "hardware gate";
                case 21: return "display Flash store error";
                default: return "protocol";
            }
        }
        private static int u16(byte[] value, int offset) {
            return (value[offset] & 0xFF) | ((value[offset + 1] & 0xFF) << 8);
        }
    }
}
