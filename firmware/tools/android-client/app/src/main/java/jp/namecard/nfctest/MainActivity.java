package jp.namecard.nfctest;

import android.app.Activity;
import android.app.PendingIntent;
import android.content.Intent;
import android.nfc.NfcAdapter;
import android.nfc.Tag;
import android.nfc.tech.NfcV;
import android.os.Bundle;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.provider.OpenableColumns;
import android.view.View;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ScrollView;
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
    private final Handler ui = new Handler(Looper.getMainLooper());
    private final AtomicBoolean running = new AtomicBoolean(false);
    private NfcAdapter adapter;
    private PendingIntent pendingIntent;
    private TextView status;
    private Button choose;
    private byte[] image;

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        adapter = NfcAdapter.getDefaultAdapter(this);
        pendingIntent = PendingIntent.getActivity(this, 0,
                new Intent(this, getClass()).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
                PendingIntent.FLAG_MUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);

        LinearLayout content = new LinearLayout(this);
        content.setOrientation(LinearLayout.VERTICAL);
        content.setPadding(32, 40, 32, 40);
        choose = new Button(this);
        choose.setText("4736-byte画像を選択");
        choose.setOnClickListener(this::chooseImage);
        content.addView(choose);
        status = new TextView(this);
        status.setTextSize(16);
        status.setText("EPD_NATIVE_1BPP画像を選択してください。\n1=白、MSB first、SSD1680 RAM順です。");
        content.addView(status);
        ScrollView scroll = new ScrollView(this);
        scroll.addView(content);
        setContentView(scroll);
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
        if (adapter != null) adapter.enableForegroundDispatch(this, pendingIntent, null, null);
    }

    @Override protected void onPause() {
        if (adapter != null) adapter.disableForegroundDispatch(this);
        super.onPause();
    }

    @Override protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        Tag tag = Build.VERSION.SDK_INT >= 33
                ? intent.getParcelableExtra(NfcAdapter.EXTRA_TAG, Tag.class)
                : intent.getParcelableExtra(NfcAdapter.EXTRA_TAG);
        if (tag == null || image == null || !running.compareAndSet(false, true)) return;
        byte[] transferImage = Arrays.copyOf(image, image.length);
        choose.setEnabled(false);
        new Thread(() -> transfer(tag, transferImage), "namecard-ftm").start();
    }

    private void transfer(Tag tag, byte[] transferImage) {
        NfcV nfc = NfcV.get(tag);
        try {
            if (nfc == null) throw new IllegalStateException("NFC-Vタグではありません");
            nfc.connect();
            St25Mailbox mailbox = new St25Mailbox(nfc, tag.getId());
            mailbox.enable();
            int transferId = (int)(System.currentTimeMillis() & 0xFFFF);
            int maxChunk = Math.min(240, nfc.getMaxTransceiveLength() - 28);
            if (maxChunk < 32) throw new IllegalStateException("NFC転送長が不足しています");
            log(String.format(Locale.US, "接続: maxTx=%d, DATA payload=%d\n",
                    nfc.getMaxTransceiveLength(), maxChunk));

            CRC32 crc = new CRC32();
            crc.update(transferImage);
            ByteBuffer metadata = ByteBuffer.allocate(16).order(ByteOrder.LITTLE_ENDIAN);
            metadata.putShort((short)296).putShort((short)128).putShort((short)IMAGE_SIZE);
            metadata.put((byte)1).put((byte)1).putInt((int)crc.getValue()).putInt(0);

            int sequence = 0;
            Ack ack = mailbox.exchange(Protocol.frame(1, transferId, sequence++, 0, metadata.array()));
            ack.requireSuccess();
            for (int offset = 0; offset < transferImage.length; offset += maxChunk) {
                int end = Math.min(offset + maxChunk, transferImage.length);
                byte[] chunk = Arrays.copyOfRange(transferImage, offset, end);
                ack = mailbox.exchange(Protocol.frame(2, transferId, sequence++, offset, chunk));
                ack.requireSuccess();
                log(String.format(Locale.US, "%d / %d bytes, VDD=%dmV\n",
                        end, IMAGE_SIZE, ack.vddMv));
            }
            ack = mailbox.exchange(Protocol.frame(3, transferId, sequence++, IMAGE_SIZE, new byte[0]));
            ack.requireSuccess();

            do {
                Thread.sleep(500);
                ack = mailbox.exchange(Protocol.frame(4, transferId, sequence, IMAGE_SIZE, new byte[0]));
                ack.requireSuccess();
                log(String.format(Locale.US, "充電: state=%d VDD=%dmV min=%dmV\n",
                        ack.state, ack.vddMv, ack.minimumVddMv));
            } while (ack.state != 3);

            ack = mailbox.exchange(Protocol.frame(5, transferId, sequence, IMAGE_SIZE, new byte[0]));
            ack.requireSuccess();
            int quiet = Math.max(2000, ack.quietMs);
            log("EXECUTE ACK受信。RF通信を " + quiet + "ms 停止します。動かさないでください。\n");
            Thread.sleep(quiet + 250L); // RF field remains present while no transceive is issued.
            Ack complete = mailbox.exchange(Protocol.frame(4, transferId, sequence + 1,
                                                            IMAGE_SIZE, new byte[0]));
            complete.requireSuccess();
            if (complete.state != 6) {
                throw new IllegalStateException("更新後state=" + complete.state + " error=" + complete.error);
            }
            log(String.format(Locale.US, "完了: VDD=%dmV, 更新中min=%dmV\n",
                    complete.vddMv, complete.minimumVddMv));
        } catch (Exception error) {
            log("失敗: " + error.getMessage() + "\nSTARTから再試行してください。\n");
        } finally {
            try { if (nfc != null) nfc.close(); } catch (Exception ignored) { }
            running.set(false);
            ui.post(() -> choose.setEnabled(true));
        }
    }

    private static byte[] readAll(InputStream input) throws Exception {
        if (input == null) throw new IllegalArgumentException("ファイルを開けません");
        ByteArrayOutputStream output = new ByteArrayOutputStream();
        byte[] buffer = new byte[4096];
        int count;
        while ((count = input.read(buffer)) >= 0) output.write(buffer, 0, count);
        return output.toByteArray();
    }

    private void log(String message) {
        ui.post(() -> status.append(message));
    }

    private static final class St25Mailbox {
        private static final int FLAGS = 0x22; // addressed + high data rate
        private static final int MFG_ST = 0x02;
        private final NfcV nfc;
        private final byte[] uid;

        St25Mailbox(NfcV nfc, byte[] uid) { this.nfc = nfc; this.uid = uid; }

        void enable() throws Exception { command(0xAE, new byte[] {0x0D, 0x01}); }

        Ack exchange(byte[] message) throws Exception {
            waitMailboxFree(1000);
            byte[] write = new byte[1 + message.length];
            write[0] = (byte)(message.length - 1);
            System.arraycopy(message, 0, write, 1, message.length);
            command(0xAA, write);

            long deadline = System.currentTimeMillis() + 1500;
            while (System.currentTimeMillis() < deadline) {
                int control = readControl();
                if ((control & 0x02) != 0) return Ack.decode(readHostMessage());
                Thread.sleep(10);
            }
            throw new IllegalStateException("MCU ACK timeout");
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

        private int readControl() throws Exception { return command(0xAD, new byte[] {0x0D})[0] & 0xFF; }

        private byte[] readHostMessage() throws Exception {
            int length = (command(0xAB, new byte[0])[0] & 0xFF) + 1;
            byte[] answer = command(0xAC, new byte[] {0, (byte)(length - 1)});
            if (answer.length != length) throw new IllegalStateException("ACK length mismatch");
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
                throw new IllegalStateException(String.format(Locale.US,
                        "ST25 command %02X error %02X", code, error));
            }
            return Arrays.copyOfRange(response, 1, response.length);
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
        final int code, state, error, vddMv, minimumVddMv, quietMs;
        Ack(int code, int state, int error, int vddMv, int minimumVddMv, int quietMs) {
            this.code = code; this.state = state; this.error = error;
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
                           u16(raw, 24), u16(raw, 26), u16(raw, 28));
        }
        void requireSuccess() {
            if (code == 0x80 || error != 0) throw new IllegalStateException("FW error=" + error);
        }
        private static int u16(byte[] value, int offset) {
            return (value[offset] & 0xFF) | ((value[offset + 1] & 0xFF) << 8);
        }
    }
}
