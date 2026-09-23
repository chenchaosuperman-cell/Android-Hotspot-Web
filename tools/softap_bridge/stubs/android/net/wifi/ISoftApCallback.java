package android.net.wifi;
public interface ISoftApCallback extends android.os.IInterface {
    void onStateChanged(int state, int failureReason) throws android.os.RemoteException;
    void onCapabilityChanged(SoftApCapability capability) throws android.os.RemoteException;
    void onConnectedClientsChanged(java.util.List<?> clients) throws android.os.RemoteException;
    void onInfoChanged(SoftApInfo info) throws android.os.RemoteException;
    void onConnectedClientsChangedForApUid(int apUid, java.util.List<?> clients) throws android.os.RemoteException;
    void onClientNumChanged(int num) throws android.os.RemoteException;
    abstract class Stub extends android.os.Binder implements ISoftApCallback {
        public Stub() {}
        public android.os.IBinder asBinder() { return this; }
    }
}
