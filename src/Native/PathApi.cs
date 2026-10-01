using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
namespace GHubSwitcher {
    public sealed class PathIdentity {
        public string FinalPath { get; internal set; }
        public uint VolumeSerial { get; internal set; }
        public string FileId { get; internal set; }
        public bool IsReparsePoint { get; internal set; }
    }
    public static class PathApi {
        [StructLayout(LayoutKind.Sequential)] struct FileInfo {
            public uint Attributes; public System.Runtime.InteropServices.ComTypes.FILETIME Creation,Access,Write;
            public uint VolumeSerial,SizeHigh,SizeLow,Links,IndexHigh,IndexLow;
        }
        [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern SafeFileHandle CreateFile(string path,uint access,uint share,IntPtr security,uint mode,uint flags,IntPtr template);
        [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetFileInformationByHandle(SafeFileHandle file,out FileInfo info);
        [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern uint GetFinalPathNameByHandle(SafeFileHandle file,StringBuilder name,uint length,uint flags);
        public static PathIdentity Inspect(string path) {
            using(SafeFileHandle file=CreateFile(path,0x80,7,IntPtr.Zero,3,0x02200000,IntPtr.Zero)) {
                if(file.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
                FileInfo info; if(!GetFileInformationByHandle(file,out info)) throw new Win32Exception(Marshal.GetLastWin32Error());
                StringBuilder name=new StringBuilder(32768);
                if(GetFinalPathNameByHandle(file,name,(uint)name.Capacity,0)==0) throw new Win32Exception(Marshal.GetLastWin32Error());
                return new PathIdentity {FinalPath=name.ToString(),VolumeSerial=info.VolumeSerial,FileId=info.IndexHigh.ToString("x8")+info.IndexLow.ToString("x8"),IsReparsePoint=(info.Attributes&0x400)!=0};
            }
        }
    }
}
