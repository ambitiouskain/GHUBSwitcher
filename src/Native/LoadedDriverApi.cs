using System;
using System.Text;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace GHubSwitcher {
    public static class LoadedDriverApi {
        [DllImport("psapi.dll", SetLastError=true)] static extern bool EnumDeviceDrivers([Out] IntPtr[] addresses, uint size, out uint needed);
        [DllImport("psapi.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern uint GetDeviceDriverFileName(IntPtr address, StringBuilder name, uint size);
        [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
        [DllImport("advapi32.dll", SetLastError=true)] static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
        [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool LookupPrivilegeValue(string system, string name, out Luid luid);
        [StructLayout(LayoutKind.Sequential)] struct Luid { public uint Low; public int High; }
        [StructLayout(LayoutKind.Sequential)] struct Privileges { public uint Count; public Luid Luid; public uint Attributes; }
        [DllImport("advapi32.dll", SetLastError=true)] static extern bool AdjustTokenPrivileges(IntPtr token, bool disable, ref Privileges next, uint length, out Privileges previous, out uint returned);
        [DllImport("advapi32.dll", EntryPoint="AdjustTokenPrivileges", SetLastError=true)] static extern bool RestoreTokenPrivileges(IntPtr token, bool disable, ref Privileges previous, uint length, IntPtr ignored, IntPtr returned);
        public static string[] Enumerate() {
            IntPtr token;
            if (!OpenProcessToken(GetCurrentProcess(), 0x28, out token)) throw new Win32Exception();
            Privileges previous=new Privileges(); bool adjusted=false;
            try {
                Luid id;
                if (!LookupPrivilegeValue(null, "SeDebugPrivilege", out id)) throw new Win32Exception();
                Privileges next=new Privileges { Count=1, Luid=id, Attributes=2 }; uint returned;
                if (!AdjustTokenPrivileges(token, false, ref next, (uint)Marshal.SizeOf(typeof(Privileges)), out previous, out returned)) throw new Win32Exception();
                adjusted=true;
                int error=Marshal.GetLastWin32Error(); if (error!=0) throw new Win32Exception(error);
                IntPtr[] addresses=new IntPtr[4096]; uint needed;
                if (!EnumDeviceDrivers(addresses, (uint)(addresses.Length*IntPtr.Size), out needed)) throw new Win32Exception();
                if (needed==0 || needed>addresses.Length*IntPtr.Size) throw new InvalidOperationException("Loaded driver enumeration is incomplete.");
                string[] paths=new string[needed/IntPtr.Size];
                for (int i=0; i<paths.Length; i++) {
                    if (addresses[i]==IntPtr.Zero) throw new InvalidOperationException("Loaded driver identity is unavailable.");
                    StringBuilder name=new StringBuilder(32768);
                    if (GetDeviceDriverFileName(addresses[i], name, (uint)name.Capacity)==0) throw new Win32Exception();
                    paths[i]=name.ToString();
                }
                return paths;
            } finally {
                if (adjusted) RestoreTokenPrivileges(token, false, ref previous, 0, IntPtr.Zero, IntPtr.Zero);
                CloseHandle(token);
            }
        }
    }
}
