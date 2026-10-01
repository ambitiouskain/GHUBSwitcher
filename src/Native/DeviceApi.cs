using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32;
using Microsoft.Win32.SafeHandles;

namespace GHubSwitcher {
    public sealed class DeviceRecord {
        public string InstanceId { get; internal set; }
        public string[] HardwareIds { get; internal set; }
        public string ContainerId { get; internal set; }
        public string ParentInstanceId { get; internal set; }
        public string ClassGuid { get; internal set; }
        public string Name { get; internal set; }
        public string Service { get; internal set; }
        public string InfPath { get; internal set; }
        public string InfSection { get; internal set; }
        public string DriverVersion { get; internal set; }
        public string[] UpperFilters { get; internal set; }
        public string[] LowerFilters { get; internal set; }
        public bool Present { get; internal set; }
        public uint ProblemCode { get; internal set; }
    }
    public sealed class InfLine {
        public string Key { get; internal set; }
        public string[] Values { get; internal set; }
    }
    public static partial class DeviceApi {
        internal static readonly IntPtr Invalid = new IntPtr(-1);
        [StructLayout(LayoutKind.Sequential)] internal struct DeviceInfo { public uint cbSize; public Guid ClassGuid; public uint DevInst; public IntPtr Reserved; }
        [StructLayout(LayoutKind.Sequential)] struct PropertyKey { public Guid fmtid; public uint pid; }
        [StructLayout(LayoutKind.Sequential)] struct InfContext { public IntPtr Inf; public IntPtr CurrentInf; public uint Section; public uint Line; }
        [DllImport("setupapi.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr SetupDiGetClassDevs(IntPtr guid,string enumerator,IntPtr hwnd,uint flags);
        [DllImport("setupapi.dll", SetLastError=true)] internal static extern bool SetupDiEnumDeviceInfo(IntPtr set,uint index,ref DeviceInfo data);
        [DllImport("setupapi.dll", SetLastError=true)] internal static extern bool SetupDiDestroyDeviceInfoList(IntPtr set);
        [DllImport("setupapi.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool SetupDiGetDeviceInstanceId(IntPtr set,ref DeviceInfo data,StringBuilder text,uint size,out uint required);
        [DllImport("setupapi.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool SetupDiGetDeviceRegistryProperty(IntPtr set,ref DeviceInfo data,uint property,out uint type,byte[] buffer,uint size,out uint required);
        [DllImport("setupapi.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool SetupDiGetDeviceProperty(IntPtr set,ref DeviceInfo data,ref PropertyKey key,out uint type,byte[] buffer,uint size,out uint required,uint flags);
        [DllImport("setupapi.dll", SetLastError=true)] static extern IntPtr SetupDiOpenDevRegKey(IntPtr set,ref DeviceInfo data,uint scope,uint profile,uint type,uint access);
        [DllImport("cfgmgr32.dll")] static extern uint CM_Get_DevNode_Status(out uint status,out uint problem,uint devinst,uint flags);
        [DllImport("cfgmgr32.dll")] static extern uint CM_Get_Parent(out uint parent,uint devinst,uint flags);
        [DllImport("cfgmgr32.dll", CharSet=CharSet.Unicode)] static extern uint CM_Get_Device_ID(uint devinst,StringBuilder buffer,uint length,uint flags);
        [DllImport("setupapi.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr SetupOpenInfFile(string file,string infClass,uint style,out uint errorLine);
        [DllImport("setupapi.dll")] static extern void SetupCloseInfFile(IntPtr inf);
        [DllImport("setupapi.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool SetupFindFirstLine(IntPtr inf,string section,string key,out InfContext context);
        [DllImport("setupapi.dll", SetLastError=true)] static extern bool SetupFindNextLine(ref InfContext current,out InfContext next);
        [DllImport("setupapi.dll")] static extern uint SetupGetFieldCount(ref InfContext context);
        [DllImport("setupapi.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool SetupGetStringField(ref InfContext context,uint index,StringBuilder buffer,uint size,out uint required);
        internal static DeviceInfo NewInfo() { DeviceInfo d=new DeviceInfo(); d.cbSize=(uint)Marshal.SizeOf(typeof(DeviceInfo)); return d; }
        internal static void Check(bool ok) { if(!ok) throw new Win32Exception(Marshal.GetLastWin32Error()); }
        static string[] ReadMulti(IntPtr set,ref DeviceInfo data,uint property) {
            uint type,required; byte[] bytes=new byte[65536];
            if(!SetupDiGetDeviceRegistryProperty(set,ref data,property,out type,bytes,(uint)bytes.Length,out required)) {
                int error=Marshal.GetLastWin32Error();
                if(error==13 || error==2 || error==1168) return new string[0];
                throw new Win32Exception(error);
            }
            return Encoding.Unicode.GetString(bytes,0,(int)required).TrimEnd('\0').Split(new char[]{'\0'},StringSplitOptions.RemoveEmptyEntries);
        }
        static string ReadString(IntPtr set,ref DeviceInfo data,uint property) { string[] s=ReadMulti(set,ref data,property); return s.Length==0?"":s[0]; }
        static string KeyString(RegistryKey key,string name) { return Convert.ToString(key.GetValue(name,"",RegistryValueOptions.DoNotExpandEnvironmentNames)); }
        public static DeviceRecord[] Enumerate() {
            IntPtr set=SetupDiGetClassDevs(IntPtr.Zero,null,IntPtr.Zero,6);
            if(set==Invalid) throw new Win32Exception(Marshal.GetLastWin32Error());
            List<DeviceRecord> records=new List<DeviceRecord>();
            try {
                for(uint i=0;;i++) {
                    DeviceInfo data=NewInfo();
                    if(!SetupDiEnumDeviceInfo(set,i,ref data)) { if(Marshal.GetLastWin32Error()==259) break; throw new Win32Exception(Marshal.GetLastWin32Error()); }
                    StringBuilder id=new StringBuilder(4096); uint required;
                    Check(SetupDiGetDeviceInstanceId(set,ref data,id,(uint)id.Capacity,out required));
                    DeviceRecord r=new DeviceRecord(); r.InstanceId=id.ToString(); r.ClassGuid=data.ClassGuid.ToString("B");
                    r.HardwareIds=ReadMulti(set,ref data,1); r.Service=ReadString(set,ref data,4);
                    r.Name=ReadString(set,ref data,12); if(r.Name.Length==0) r.Name=ReadString(set,ref data,0);
                    r.UpperFilters=ReadMulti(set,ref data,17); r.LowerFilters=ReadMulti(set,ref data,18);
                    r.Present=true; uint status,problem; uint cr=CM_Get_DevNode_Status(out status,out problem,data.DevInst,0); r.ProblemCode=cr==0?problem:UInt32.MaxValue;
                    uint parent; StringBuilder parentId=new StringBuilder(4096); r.ParentInstanceId="";
                    if(CM_Get_Parent(out parent,data.DevInst,0)==0 && CM_Get_Device_ID(parent,parentId,(uint)parentId.Capacity,0)==0) r.ParentInstanceId=parentId.ToString();
                    PropertyKey container=new PropertyKey(); container.fmtid=new Guid("8c7ed206-3f8a-4827-b3ab-ae9e1faefc6c"); container.pid=2;
                    byte[] value=new byte[16]; uint type; r.ContainerId="";
                    if(SetupDiGetDeviceProperty(set,ref data,ref container,out type,value,16,out required,0) && required==16) r.ContainerId=new Guid(value).ToString();
                    r.InfPath=""; r.InfSection=""; r.DriverVersion="";
                    IntPtr keyHandle=SetupDiOpenDevRegKey(set,ref data,1,0,2,0x20019);
                    if(keyHandle!=Invalid) {
                        using(SafeRegistryHandle safe=new SafeRegistryHandle(keyHandle,true))
                        using(RegistryKey key=RegistryKey.FromHandle(safe)) {
                            r.InfPath=KeyString(key,"InfPath"); r.InfSection=KeyString(key,"InfSection"); r.DriverVersion=KeyString(key,"DriverVersion");
                        }
                    }
                    records.Add(r);
                }
            } finally { SetupDiDestroyDeviceInfoList(set); }
            return records.ToArray();
        }
        public static InfLine[] ReadInfSection(string path,string section) {
            uint errorLine; IntPtr inf=SetupOpenInfFile(path,null,2,out errorLine);
            if(inf==Invalid) throw new Win32Exception(Marshal.GetLastWin32Error());
            List<InfLine> lines=new List<InfLine>();
            try {
                InfContext context;
                if(!SetupFindFirstLine(inf,section,null,out context)) {
                    int error=Marshal.GetLastWin32Error(); if(error==unchecked((int)0xe0000101) || error==unchecked((int)0xe0000102)) return lines.ToArray();
                    throw new Win32Exception(error);
                }
                do {
                    uint n=SetupGetFieldCount(ref context); List<string> values=new List<string>(); string key="";
                    for(uint i=0;i<=n;i++) {
                        StringBuilder b=new StringBuilder(32768); uint required;
                        if(!SetupGetStringField(ref context,i,b,(uint)b.Capacity,out required)) { if(i==0) continue; throw new Win32Exception(Marshal.GetLastWin32Error()); }
                        if(i==0) key=b.ToString(); else values.Add(b.ToString());
                    }
                    lines.Add(new InfLine {Key=key,Values=values.ToArray()});
                    InfContext next; if(!SetupFindNextLine(ref context,out next)) break; context=next;
                } while(true);
            } finally { SetupCloseInfFile(inf); }
            return lines.ToArray();
        }
    }
}
