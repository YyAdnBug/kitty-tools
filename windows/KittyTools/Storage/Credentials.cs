// 凭据管理器：翻译服务的密钥只进 Windows Credential Manager（CRED_TYPE_GENERIC，
// CRED_PERSIST_LOCAL_MACHINE）。目标名 KittyTools/<服务 id>.<字段>；Debug 版 KittyTools.Dev/…
// 日志和错误信息里不出现密钥。
// CREDENTIALW 的布局自己写：CsWin32 生成的版本在这里用起来别扭，字段又少。
using System.Runtime.InteropServices;
using System.Text;

namespace KittyTools.Infrastructure;

internal static unsafe partial class Credentials
{
    private const int TypeGeneric = 1;
    private const uint PersistLocalMachine = 2;

    public static string? Get(string name)
    {
        if (!CredRead(name, TypeGeneric, 0, out var raw) || raw == IntPtr.Zero)
        {
            return null;
        }

        try
        {
            var credential = (Credential*)raw;
            var size = credential->CredentialBlobSize;
            if (credential->CredentialBlob == IntPtr.Zero || size == 0)
            {
                return string.Empty;
            }

            // CredWrite 存的是 UTF-16 字节（不带结尾 \0）。
            return new string((char*)credential->CredentialBlob, 0, (int)(size / sizeof(char)));
        }
        finally
        {
            CredFree(raw);
        }
    }

    public static bool Set(string name, string value)
    {
        var bytes = Encoding.Unicode.GetBytes(value);
        fixed (char* target = name)
        fixed (char* user = Paths.ProductName)
        fixed (byte* blob = bytes)
        {
            var credential = new Credential
            {
                Type = TypeGeneric,
                TargetName = (IntPtr)target,
                CredentialBlobSize = (uint)bytes.Length,
                CredentialBlob = (IntPtr)blob,
                Persist = PersistLocalMachine,
                UserName = (IntPtr)user,
            };
            return CredWrite(ref credential, 0);
        }
    }

    public static bool Delete(string name) => CredDelete(name, TypeGeneric, 0);

    /// <summary>TargetName 是 KittyTools/… 或 KittyTools.Dev/…，由调用方拼服务 id 和字段名。</summary>
    public static string Target(string name) => Paths.CredentialPrefix + name;

    [StructLayout(LayoutKind.Sequential)]
    private struct Credential
    {
        public uint Flags;
        public uint Type;
        public IntPtr TargetName;
        public IntPtr Comment;
        public long LastWritten;
        public uint CredentialBlobSize;
        public IntPtr CredentialBlob;
        public uint Persist;
        public uint AttributeCount;
        public IntPtr Attributes;
        public IntPtr TargetAlias;
        public IntPtr UserName;
    }

    [LibraryImport("advapi32.dll", EntryPoint = "CredReadW", SetLastError = true, StringMarshalling = StringMarshalling.Utf16)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool CredRead(string target, int type, uint flags, out IntPtr credential);

    [LibraryImport("advapi32.dll", EntryPoint = "CredWriteW", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool CredWrite(ref Credential credential, uint flags);

    [LibraryImport("advapi32.dll", EntryPoint = "CredDeleteW", SetLastError = true, StringMarshalling = StringMarshalling.Utf16)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool CredDelete(string target, int type, uint flags);

    [LibraryImport("advapi32.dll", EntryPoint = "CredFree")]
    private static partial void CredFree(IntPtr credential);
}
