package android.net;
public interface IIntResultListener extends android.os.IInterface {
    void onResult(int res) throws android.os.RemoteException;
    abstract class Stub extends android.os.Binder implements IIntResultListener {
        public Stub() {}
        public android.os.IBinder asBinder() { return this; }
    }
}
