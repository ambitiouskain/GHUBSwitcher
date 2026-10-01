using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;
namespace GHubSwitcher {
    public sealed class DriverInstallResult { public bool Success; public bool NeedReboot; public string InfPath; public string Section; }
    public static partial class DeviceApi {
        [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] struct InstallParams {
            public uint cbSize,Flags,FlagsEx; public IntPtr hwndParent,InstallMsgHandler,InstallMsgHandlerContext,FileQueue,ClassInstallReserved;
            public uint Reserved; [MarshalAs(UnmanagedType.ByValTStr,SizeConst=260)] public string DriverPath;
        }
        [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] struct DriverInfo {
            public uint cbSize,DriverType; public IntPtr Reserved;
            [MarshalAs(UnmanagedType.ByValTStr,SizeConst=256)] public string Description;
            [MarshalAs(UnmanagedType.ByValTStr,SizeConst=256)] public string Manufacturer;
            [MarshalAs(UnmanagedType.ByValTStr,SizeConst=256)] public string Provider;
            public System.Runtime.InteropServices.ComTypes.FILETIME Date; public ulong Version;
        }
        [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] struct DriverDetail {
            public uint cbSize; public System.Runtime.InteropServices.ComTypes.FILETIME Date; public uint CompatOffset,CompatLength; public IntPtr Reserved;
            [MarshalAs(UnmanagedType.ByValTStr,SizeConst=256)] public string Section;
            [MarshalAs(UnmanagedType.ByValTStr,SizeConst=260)] public string Inf;
            [MarshalAs(UnmanagedType.ByValTStr,SizeConst=256)] public string Description;
            public char HardwareId;
        }
        [DllImport("setupapi.dll",SetLastError=true)] static extern IntPtr SetupDiCreateDeviceInfoList(IntPtr guid,IntPtr parent);
        [DllImport("setupapi.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool SetupDiOpenDeviceInfo(IntPtr set,string id,IntPtr parent,uint flags,ref DeviceInfo info);
        [DllImport("setupapi.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool SetupDiGetDeviceInstallParams(IntPtr set,ref DeviceInfo info,ref InstallParams parameters);
        [DllImport("setupapi.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool SetupDiSetDeviceInstallParams(IntPtr set,ref DeviceInfo info,ref InstallParams parameters);
        [DllImport("setupapi.dll",SetLastError=true)] static extern bool SetupDiBuildDriverInfoList(IntPtr set,ref DeviceInfo info,uint type);
        [DllImport("setupapi.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool SetupDiEnumDriverInfo(IntPtr set,ref DeviceInfo info,uint type,uint index,ref DriverInfo driver);
        [DllImport("setupapi.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool SetupDiGetDriverInfoDetail(IntPtr set,ref DeviceInfo info,ref DriverInfo driver,ref DriverDetail detail,uint size,out uint required);
        [DllImport("setupapi.dll",SetLastError=true)] static extern bool SetupDiDestroyDriverInfoList(IntPtr set,ref DeviceInfo info,uint type);
        [DllImport("newdev.dll",SetLastError=true)] static extern bool DiInstallDevice(IntPtr parent,IntPtr set,ref DeviceInfo device,ref DriverInfo driver,uint flags,out bool reboot);
        [DllImport("setupapi.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool SetupCopyOEMInf(string source,string media,uint mediaType,uint style,StringBuilder destination,uint size,out uint required,IntPtr component);
        [DllImport("setupapi.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool SetupDiSetDeviceRegistryProperty(IntPtr set,ref DeviceInfo device,uint property,byte[] buffer,uint length);
        static void RequireAdmin() { if(!new WindowsPrincipal(WindowsIdentity.GetCurrent()).IsInRole(WindowsBuiltInRole.Administrator)) throw new UnauthorizedAccessException("AccessDenied"); if(IntPtr.Size!=8) throw new InvalidOperationException("x64 required"); }
        public static string StagePackage(string infPath) {
            RequireAdmin(); StringBuilder result=new StringBuilder(32768); uint required;
            Check(SetupCopyOEMInf(Path.GetFullPath(infPath),null,1,0,result,(uint)result.Capacity,out required,IntPtr.Zero));
            return result.ToString();
        }
        public static DriverInstallResult InstallExact(string instanceId,string publishedInfPath,string sectionName) {
            RequireAdmin(); IntPtr set=SetupDiCreateDeviceInfoList(IntPtr.Zero,IntPtr.Zero);
            if(set==Invalid) throw new Win32Exception(Marshal.GetLastWin32Error());
            DeviceInfo device=NewInfo(); bool list=false;
            try {
                Check(SetupDiOpenDeviceInfo(set,instanceId,IntPtr.Zero,0,ref device));
                InstallParams p=new InstallParams(); p.cbSize=(uint)Marshal.SizeOf(typeof(InstallParams));
                Check(SetupDiGetDeviceInstallParams(set,ref device,ref p));
                p.Flags|=0x00010000; p.DriverPath=Path.GetFullPath(publishedInfPath);
                if(p.DriverPath.Length>=260) throw new ArgumentException("INF path exceeds SetupAPI limit");
                Check(SetupDiSetDeviceInstallParams(set,ref device,ref p));
                Check(SetupDiBuildDriverInfoList(set,ref device,2)); list=true;
                List<DriverInfo> candidates=new List<DriverInfo>();
                for(uint i=0;;i++) {
                    DriverInfo driver=new DriverInfo(); driver.cbSize=(uint)Marshal.SizeOf(typeof(DriverInfo));
                    if(!SetupDiEnumDriverInfo(set,ref device,2,i,ref driver)) { if(Marshal.GetLastWin32Error()==259) break; throw new Win32Exception(Marshal.GetLastWin32Error()); }
                    DriverDetail detail=new DriverDetail(); detail.cbSize=(uint)Marshal.SizeOf(typeof(DriverDetail)); uint required;
                    bool got=SetupDiGetDriverInfoDetail(set,ref device,ref driver,ref detail,detail.cbSize,out required);
                    if(!got && Marshal.GetLastWin32Error()!=122) throw new Win32Exception(Marshal.GetLastWin32Error());
                    if(String.Equals(Path.GetFullPath(detail.Inf),Path.GetFullPath(publishedInfPath),StringComparison.OrdinalIgnoreCase) && String.Equals(detail.Section,sectionName,StringComparison.OrdinalIgnoreCase)) candidates.Add(driver);
                }
                if(candidates.Count!=1) throw new InvalidOperationException("DeviceAmbiguous: expected one compatible driver candidate, got "+candidates.Count);
                DriverInfo selected=candidates[0]; bool reboot;
                Check(DiInstallDevice(IntPtr.Zero,set,ref device,ref selected,0,out reboot));
                return new DriverInstallResult {Success=true,NeedReboot=reboot,InfPath=publishedInfPath,Section=sectionName};
            } finally { if(list) SetupDiDestroyDriverInfoList(set,ref device,2); SetupDiDestroyDeviceInfoList(set); }
        }
        public static void SetDeviceFilters(string instanceId,string[] upper,string[] lower) {
            RequireAdmin(); IntPtr set=SetupDiCreateDeviceInfoList(IntPtr.Zero,IntPtr.Zero);
            if(set==Invalid) throw new Win32Exception(Marshal.GetLastWin32Error());
            try {
                DeviceInfo info=NewInfo(); Check(SetupDiOpenDeviceInfo(set,instanceId,IntPtr.Zero,0,ref info));
                SetFilters(set,ref info,17,upper); SetFilters(set,ref info,18,lower);
            } finally { SetupDiDestroyDeviceInfoList(set); }
        }
        static void SetFilters(IntPtr set,ref DeviceInfo info,uint property,string[] filters) {
            if(filters==null) throw new ArgumentNullException("filters");
            foreach(string filter in filters) if(String.IsNullOrWhiteSpace(filter)||filter.IndexOf('\0')>=0) throw new ArgumentException("Invalid filter name");
            byte[] data=filters.Length==0?null:Encoding.Unicode.GetBytes(String.Join("\0",filters)+"\0\0");
            if(!SetupDiSetDeviceRegistryProperty(set,ref info,property,data,data==null?0:(uint)data.Length)) {
                int error=Marshal.GetLastWin32Error(); if(data==null && error==13) return; throw new Win32Exception(error);
            }
        }
    }
}
