using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Threading;
using Microsoft.Win32.SafeHandles;
public static class DirectoryLockFixture {
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern SafeFileHandle CreateFile(string path,uint access,uint share,IntPtr security,uint mode,uint flags,IntPtr template);
    public static SafeFileHandle Hold(string path) {
        SafeFileHandle handle=CreateFile(path,0x1,3,IntPtr.Zero,3,0x02200000,IntPtr.Zero);
        if(handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
        return handle;
    }
    public static Thread HoldBriefly(string path,int milliseconds) {
        SafeFileHandle handle=Hold(path);
        Thread thread=new Thread(delegate(){Thread.Sleep(milliseconds);handle.Dispose();});
        thread.IsBackground=true;thread.Start();return thread;
    }
}
