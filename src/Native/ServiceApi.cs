using System;
using System.ComponentModel;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.IO;
using System.Security.Cryptography;
using System.Diagnostics;
using System.Threading;
namespace GHubSwitcher {
    public sealed class FailureAction { public uint Type; public uint Delay; }
    public sealed class ServiceRestorePolicy { public uint AccessMask,StartType; public FailureAction[] FailureActions; }
    public sealed class ServiceRecord {
        public string Name,ImagePath,Account,DisplayName,LoadOrderGroup,RebootMessage,FailureCommand;
        public uint ServiceType,StartType,ErrorControl,ResetPeriod,TriggerCount,TagId,CurrentState,ControlsAccepted;
        public bool DelayedAutoStart;
        public string[] Dependencies;
        public FailureAction[] FailureActions;
    }
    public static class ServiceApi {
        [StructLayout(LayoutKind.Sequential)] struct Config { public uint Type,Start,Error; public IntPtr Path,Group; public uint Tag; public IntPtr Dependencies,Account,Display; }
        [StructLayout(LayoutKind.Sequential)] struct Failure { public uint Reset; public IntPtr Message,Command; public uint Count; public IntPtr Actions; }
        [StructLayout(LayoutKind.Sequential)] struct ActionItem { public uint Type,Delay; }
        [StructLayout(LayoutKind.Sequential)] struct Status { public uint Type,State,Accepted,Win32Exit,SpecificExit,Checkpoint,WaitHint; }
        [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr OpenSCManager(string machine,string database,uint access);
        [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr OpenService(IntPtr manager,string name,uint access);
        [DllImport("advapi32.dll",SetLastError=true)] static extern bool CloseServiceHandle(IntPtr service);
        [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool QueryServiceConfig(IntPtr service,IntPtr config,uint size,out uint required);
        [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool QueryServiceConfig2(IntPtr service,uint level,IntPtr config,uint size,out uint required);
        [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool ChangeServiceConfig(IntPtr service,uint type,uint start,uint error,string path,string group,IntPtr tag,string dependencies,string account,string password,string display);
        [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool ChangeServiceConfig2(IntPtr service,uint level,IntPtr info);
        [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr CreateService(IntPtr manager,string name,string display,uint access,uint type,uint start,uint error,string path,string group,IntPtr tag,string dependencies,string account,string password);
        [DllImport("advapi32.dll",SetLastError=true)] static extern bool QueryServiceStatus(IntPtr service,out Status status);
        [DllImport("advapi32.dll",SetLastError=true)] static extern bool ControlService(IntPtr service,uint control,out Status status);
        [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool StartService(IntPtr service,uint count,IntPtr arguments);
        static string S(IntPtr p) { return p==IntPtr.Zero?"":Marshal.PtrToStringUni(p); }
        static string[] Multi(IntPtr p) {
            List<string> values=new List<string>(); if(p==IntPtr.Zero) return values.ToArray();
            while(Marshal.ReadInt16(p)!=0) { string s=Marshal.PtrToStringUni(p); values.Add(s); p=IntPtr.Add(p,(s.Length+1)*2); }
            return values.ToArray();
        }
        static IntPtr Query(IntPtr service,uint level) {
            uint size; bool ok=level==0?QueryServiceConfig(service,IntPtr.Zero,0,out size):QueryServiceConfig2(service,level,IntPtr.Zero,0,out size);
            int error=Marshal.GetLastWin32Error(); if(!ok && error!=122) throw new Win32Exception(error);
            IntPtr result=Marshal.AllocHGlobal((int)size);
            ok=level==0?QueryServiceConfig(service,result,size,out size):QueryServiceConfig2(service,level,result,size,out size);
            if(!ok) { error=Marshal.GetLastWin32Error(); Marshal.FreeHGlobal(result); throw new Win32Exception(error); }
            return result;
        }
        static void RequireAdministrator() {
            if(!new WindowsPrincipal(WindowsIdentity.GetCurrent()).IsInRole(WindowsBuiltInRole.Administrator)) throw new UnauthorizedAccessException("AccessDenied");
        }
        static Status ReadStatus(IntPtr service) {
            Status value;if(!QueryServiceStatus(service,out value))throw new Win32Exception(Marshal.GetLastWin32Error());return value;
        }
        static ServiceRecord ReadKernelRecord(IntPtr service,string name) {
            IntPtr p=Query(service,0);
            try {
                Config c=(Config)Marshal.PtrToStructure(p,typeof(Config));Status status=ReadStatus(service);
                return new ServiceRecord{Name=name,ImagePath=S(c.Path),Account=S(c.Account),DisplayName=S(c.Display),LoadOrderGroup=S(c.Group),ServiceType=c.Type,StartType=c.Start,ErrorControl=c.Error,TagId=c.Tag,Dependencies=Multi(c.Dependencies),FailureActions=new FailureAction[0],CurrentState=status.State,ControlsAccepted=status.Accepted};
            } finally {Marshal.FreeHGlobal(p);}
        }
        static string AppLocalKernelPath(string imagePath) {
            string value=imagePath??"";
            if(value.StartsWith(@"\??\",StringComparison.Ordinal))value=value.Substring(4);
            if(value.Length<3 || !Char.IsLetter(value[0]) || value[1]!=':' || (value[2]!='\\' && value[2]!='/'))throw new InvalidOperationException("Unowned app-local kernel path");
            string path=Path.GetFullPath(value);
            string expected=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),@"LGHUB\logi_core_temp.sys");
            if(!String.Equals(path,expected,StringComparison.OrdinalIgnoreCase))throw new InvalidOperationException("Unowned app-local kernel path");
            return path;
        }
        public static void ValidateAppLocalKernelRecord(ServiceRecord value) {
            if(value==null || !String.Equals(value.Name,"LGHUBTemperatureService",StringComparison.OrdinalIgnoreCase) || value.ServiceType!=1)throw new InvalidOperationException("Unowned app-local kernel service");
            AppLocalKernelPath(value.ImagePath);
            // This vendor component has no load-order group, tag, dependencies, or user account.
            // Refuse unsupported kernel configurations instead of applying Win32-service options.
            if(value.StartType<2 || value.StartType>4 || value.ErrorControl>3 || value.TagId!=0 || !String.IsNullOrEmpty(value.LoadOrderGroup) || (value.Dependencies!=null && value.Dependencies.Length!=0) || !String.IsNullOrEmpty(value.Account) || value.TriggerCount!=0 || value.DelayedAutoStart || (value.FailureActions!=null && value.FailureActions.Length!=0))throw new InvalidOperationException("Unsupported app-local kernel configuration");
        }
        static bool SameKernelConfiguration(ServiceRecord a,ServiceRecord b) {
            ValidateAppLocalKernelRecord(a);ValidateAppLocalKernelRecord(b);
            return String.Equals(AppLocalKernelPath(a.ImagePath),AppLocalKernelPath(b.ImagePath),StringComparison.OrdinalIgnoreCase) && a.ErrorControl==b.ErrorControl && String.Equals(a.Account??"",b.Account??"",StringComparison.OrdinalIgnoreCase) && String.Equals(a.DisplayName??"",b.DisplayName??"",StringComparison.Ordinal);
        }
        public static bool KeepRunningAppLocalKernel(ServiceRecord current,ServiceRecord target,bool start) {
            ValidateAppLocalKernelRecord(current);ValidateAppLocalKernelRecord(target);
            if(current.CurrentState==1)return false;
            if(start && current.CurrentState==4 && current.StartType==target.StartType && SameKernelConfiguration(current,target))return true;
            throw new InvalidOperationException("App-local kernel must be stopped before restoring configuration; restart required");
        }
        static FileStream PinKernelBinary(ServiceRecord value,string sha256) {
            if(sha256==null || !System.Text.RegularExpressions.Regex.IsMatch(sha256,@"\A[0-9a-fA-F]{64}\z"))throw new InvalidOperationException("Missing kernel file identity");
            FileStream stream=new FileStream(AppLocalKernelPath(value.ImagePath),FileMode.Open,FileAccess.Read,FileShare.Read);
            try {
                using(SHA256 hash=SHA256.Create())if(!String.Equals(BitConverter.ToString(hash.ComputeHash(stream)).Replace("-",""),sha256,StringComparison.OrdinalIgnoreCase))throw new InvalidOperationException("Kernel binary changed after validation");
                return stream;
            } catch {stream.Dispose();throw;}
        }
        static void WaitForKernelState(IntPtr service,uint expected,uint timeoutMilliseconds) {
            if(timeoutMilliseconds==0 || timeoutMilliseconds>30000)throw new ArgumentOutOfRangeException("timeoutMilliseconds");
            Stopwatch clock=Stopwatch.StartNew();
            do {if(ReadStatus(service).State==expected)return;Thread.Sleep(100);}while(clock.ElapsedMilliseconds<timeoutMilliseconds);
            throw new TimeoutException("App-local kernel did not reach the required SCM state");
        }
        public static ServiceRecord CaptureKernel(string name) {
            if(!String.Equals(name,"LGHUBTemperatureService",StringComparison.OrdinalIgnoreCase))throw new InvalidOperationException("Unowned app-local kernel service");
            IntPtr manager=OpenSCManager(null,null,1);if(manager==IntPtr.Zero)throw new Win32Exception(Marshal.GetLastWin32Error());IntPtr service=IntPtr.Zero;
            try {service=OpenService(manager,name,5);if(service==IntPtr.Zero)throw new Win32Exception(Marshal.GetLastWin32Error());ServiceRecord value=ReadKernelRecord(service,name);ValidateAppLocalKernelRecord(value);return value;}
            finally {if(service!=IntPtr.Zero)CloseServiceHandle(service);CloseServiceHandle(manager);}
        }
        public static void QuiesceAppLocalKernel(ServiceRecord expected,string sha256,uint timeoutMilliseconds) {
            RequireAdministrator();ValidateAppLocalKernelRecord(expected);
            using(FileStream pinned=PinKernelBinary(expected,sha256)) {
                IntPtr manager=OpenSCManager(null,null,1);if(manager==IntPtr.Zero)throw new Win32Exception(Marshal.GetLastWin32Error());IntPtr service=IntPtr.Zero;
                try {
                    service=OpenService(manager,expected.Name,0x27);if(service==IntPtr.Zero)throw new Win32Exception(Marshal.GetLastWin32Error());
                    ServiceRecord current=ReadKernelRecord(service,expected.Name);if(!SameKernelConfiguration(current,expected))throw new InvalidOperationException("Kernel service configuration changed");
                    if(!ChangeServiceConfig(service,UInt32.MaxValue,4,UInt32.MaxValue,null,null,IntPtr.Zero,null,null,null,null))throw new Win32Exception(Marshal.GetLastWin32Error());
                    Status status=ReadStatus(service);
                    if(status.State!=1 && status.State!=3 && !ControlService(service,1,out status)) {int error=Marshal.GetLastWin32Error();if(error!=1062)throw new Win32Exception(error);}
                    WaitForKernelState(service,1,timeoutMilliseconds);
                } finally {if(service!=IntPtr.Zero)CloseServiceHandle(service);CloseServiceHandle(manager);}
            }
        }
        public static void RestoreAppLocalKernel(ServiceRecord value,string sha256,bool start,uint timeoutMilliseconds) {
            RequireAdministrator();ValidateAppLocalKernelRecord(value);
            using(FileStream pinned=PinKernelBinary(value,sha256)) {
                IntPtr manager=OpenSCManager(null,null,3);if(manager==IntPtr.Zero)throw new Win32Exception(Marshal.GetLastWin32Error());IntPtr service=IntPtr.Zero;
                try {
                    service=OpenService(manager,value.Name,0x17);
                    if(service==IntPtr.Zero) {
                        int error=Marshal.GetLastWin32Error();if(error!=1060)throw new Win32Exception(error);
                        service=CreateService(manager,value.Name,value.DisplayName,0x17,1,4,value.ErrorControl,value.ImagePath,null,IntPtr.Zero,"\0\0",String.IsNullOrEmpty(value.Account)?null:value.Account,null);
                        if(service==IntPtr.Zero)throw new Win32Exception(Marshal.GetLastWin32Error());
                    }
                    ServiceRecord current=ReadKernelRecord(service,value.Name);ValidateAppLocalKernelRecord(current);
                    if(KeepRunningAppLocalKernel(current,value,start))return;
                    if(!ChangeServiceConfig(service,1,value.StartType,value.ErrorControl,value.ImagePath,null,IntPtr.Zero,"\0\0",null,null,value.DisplayName))throw new Win32Exception(Marshal.GetLastWin32Error());
                    if(start) {if(!StartService(service,0,IntPtr.Zero))throw new Win32Exception(Marshal.GetLastWin32Error());WaitForKernelState(service,4,timeoutMilliseconds);}
                } finally {if(service!=IntPtr.Zero)CloseServiceHandle(service);CloseServiceHandle(manager);}
            }
        }
        public static ServiceRecord Capture(string name) {
            IntPtr manager=OpenSCManager(null,null,1); if(manager==IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
            IntPtr service=IntPtr.Zero;
            try {
                service=OpenService(manager,name,1); if(service==IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
                ServiceRecord result=new ServiceRecord(); result.Name=name;
                IntPtr p=Query(service,0);
                try { Config c=(Config)Marshal.PtrToStructure(p,typeof(Config)); result.ImagePath=S(c.Path);result.Account=S(c.Account);result.DisplayName=S(c.Display);result.LoadOrderGroup=S(c.Group);result.ServiceType=c.Type;result.StartType=c.Start;result.ErrorControl=c.Error;result.Dependencies=Multi(c.Dependencies); } finally {Marshal.FreeHGlobal(p);}
                p=Query(service,3); try {result.DelayedAutoStart=Marshal.ReadInt32(p)!=0;} finally {Marshal.FreeHGlobal(p);}
                p=Query(service,8); try {result.TriggerCount=(uint)Marshal.ReadInt32(p);} finally {Marshal.FreeHGlobal(p);}
                p=Query(service,2);
                try {
                    Failure f=(Failure)Marshal.PtrToStructure(p,typeof(Failure)); result.ResetPeriod=f.Reset;result.RebootMessage=S(f.Message);result.FailureCommand=S(f.Command);
                    result.FailureActions=new FailureAction[f.Count];
                    for(int i=0;i<f.Count;i++) {ActionItem a=(ActionItem)Marshal.PtrToStructure(IntPtr.Add(f.Actions,i*8),typeof(ActionItem));result.FailureActions[i]=new FailureAction{Type=a.Type,Delay=a.Delay};}
                } finally {Marshal.FreeHGlobal(p);}
                return result;
            } finally {if(service!=IntPtr.Zero)CloseServiceHandle(service);CloseServiceHandle(manager);}
        }
        public static ServiceRestorePolicy GetRestorePolicy(ServiceRecord value,bool managed,bool quiesce) {
            FailureAction[] actions=managed?new FailureAction[0]:value.FailureActions??new FailureAction[0];
            uint access=3;
            foreach(FailureAction action in actions) if(action.Type==1) access|=0x10; // SERVICE_START for SC_ACTION_RESTART
            return new ServiceRestorePolicy { AccessMask=access,StartType=quiesce?4:(managed?3:value.StartType),FailureActions=actions };
        }
        public static void Restore(ServiceRecord value,bool managed) { Restore(value,managed,false); }
        public static void SetKernelStartMode(string name,uint start) {
            if(!new WindowsPrincipal(WindowsIdentity.GetCurrent()).IsInRole(WindowsBuiltInRole.Administrator)) throw new UnauthorizedAccessException("AccessDenied");
            if(start>4 || !System.Text.RegularExpressions.Regex.IsMatch(name,@"^(logi_joy_|logi_lamparray$|lghub)",System.Text.RegularExpressions.RegexOptions.IgnoreCase)) throw new InvalidOperationException("Unowned kernel component");
            IntPtr manager=OpenSCManager(null,null,1);if(manager==IntPtr.Zero)throw new Win32Exception(Marshal.GetLastWin32Error());
            IntPtr service=IntPtr.Zero;
            try {
                service=OpenService(manager,name,3);if(service==IntPtr.Zero)throw new Win32Exception(Marshal.GetLastWin32Error());
                IntPtr p=Query(service,0);
                try {Config c=(Config)Marshal.PtrToStructure(p,typeof(Config));if((c.Type&3)==0)throw new InvalidOperationException("Not a kernel driver");}finally{Marshal.FreeHGlobal(p);}
                if(!ChangeServiceConfig(service,UInt32.MaxValue,start,UInt32.MaxValue,null,null,IntPtr.Zero,null,null,null,null))throw new Win32Exception(Marshal.GetLastWin32Error());
            }finally{if(service!=IntPtr.Zero)CloseServiceHandle(service);CloseServiceHandle(manager);}
        }
        public static void Restore(ServiceRecord value,bool managed,bool quiesce) {
            if(!new WindowsPrincipal(WindowsIdentity.GetCurrent()).IsInRole(WindowsBuiltInRole.Administrator)) throw new UnauthorizedAccessException("AccessDenied");
            if(value.TriggerCount!=0) throw new InvalidOperationException("SharedDependency: service triggers require separate review");
            if(!String.Equals(value.Account,"LocalSystem",StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("UnsupportedServiceAccount");
            if((value.ServiceType&0x30)==0) throw new InvalidOperationException("Kernel service must be installed via its INF");
            IntPtr manager=OpenSCManager(null,null,3);if(manager==IntPtr.Zero)throw new Win32Exception(Marshal.GetLastWin32Error());
            IntPtr service=IntPtr.Zero;
            try {
                ServiceRestorePolicy policy=GetRestorePolicy(value,managed,quiesce);
                uint start=policy.StartType;
                string deps=String.Join("\0",value.Dependencies??new string[0])+"\0\0";
                service=OpenService(manager,value.Name,policy.AccessMask);
                if(service==IntPtr.Zero) {
                    int error=Marshal.GetLastWin32Error();if(error!=1060)throw new Win32Exception(error);
                    service=CreateService(manager,value.Name,value.DisplayName,policy.AccessMask,value.ServiceType,start,value.ErrorControl,value.ImagePath,value.LoadOrderGroup,IntPtr.Zero,deps,value.Account,null);
                    if(service==IntPtr.Zero)throw new Win32Exception(Marshal.GetLastWin32Error());
                } else if(!ChangeServiceConfig(service,value.ServiceType,start,value.ErrorControl,value.ImagePath,value.LoadOrderGroup,IntPtr.Zero,deps,null,null,value.DisplayName)) throw new Win32Exception(Marshal.GetLastWin32Error());
                IntPtr delay=Marshal.AllocHGlobal(4);try {Marshal.WriteInt32(delay,(!managed&&value.DelayedAutoStart)?1:0);if(!ChangeServiceConfig2(service,3,delay))throw new Win32Exception(Marshal.GetLastWin32Error());}finally{Marshal.FreeHGlobal(delay);}
                Failure f=new Failure(); f.Reset=value.ResetPeriod;
                f.Message=Marshal.StringToHGlobalUni(value.RebootMessage??"");f.Command=Marshal.StringToHGlobalUni(value.FailureCommand??"");
                FailureAction[] actions=policy.FailureActions;f.Count=(uint)actions.Length;f.Actions=Marshal.AllocHGlobal(Math.Max(8,actions.Length*8));
                IntPtr fp=Marshal.AllocHGlobal(Marshal.SizeOf(typeof(Failure)));
                try {
                    for(int i=0;i<actions.Length;i++){Marshal.WriteInt32(f.Actions,i*8,(int)actions[i].Type);Marshal.WriteInt32(f.Actions,i*8+4,(int)actions[i].Delay);}
                    Marshal.StructureToPtr(f,fp,false);if(!ChangeServiceConfig2(service,2,fp))throw new Win32Exception(Marshal.GetLastWin32Error());
                }finally{Marshal.FreeHGlobal(fp);Marshal.FreeHGlobal(f.Actions);Marshal.FreeHGlobal(f.Message);Marshal.FreeHGlobal(f.Command);}
            }finally{if(service!=IntPtr.Zero)CloseServiceHandle(service);CloseServiceHandle(manager);}
        }
    }
}
