// 导出文件里的密钥：PBKDF2-HMAC-SHA256 → AES-256-GCM（第三版 §2.2，和 mac 的参数一字不差）。
// 参数：600000 轮、16 字节随机盐、32 字节密钥；密码先转 NFC；附加校验数据是各服务的「id、种类、协议、地址、
// 走不走 DeepLX」，每项写成「字节数:内容」连起来——文件里某个服务的地址被改过，密钥就解不开。
// sealed = 12 字节随机数 + 密文 + 16 字节校验（AES-GCM 的 combined），存 base64。
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace KittyTools.Core;

public static class ArchiveCrypto
{
    public const int Rounds = 600_000;

    public const int AcceptedMaxRounds = 10_000_000;

    public const int MinSaltBytes = 8;

    public const int MaxSaltBytes = 64;

    public const string Algorithm = "pbkdf2-hmac-sha256";

    /// <summary>把密钥封进文件（新的随机盐、新的随机数）。</summary>
    public static SettingsArchive.ArchiveSecrets Seal(
        IReadOnlyDictionary<string, string> secrets,
        string password,
        IReadOnlyList<SettingsArchive.ArchiveService> services)
    {
        var salt = RandomNumberGenerator.GetBytes(16);
        var key = Key(password, salt, Rounds);
        var plain = JsonSerializer.SerializeToUtf8Bytes(
            secrets, ArchiveCryptoJsonContext.Default.DictionaryStringString);
        var nonce = RandomNumberGenerator.GetBytes(12);
        var cipher = new byte[plain.Length];
        var tag = new byte[16];
        using (var aes = new AesGcm(key, 16))
        {
            aes.Encrypt(nonce, plain, cipher, tag, Routing(services));
        }

        var combined = new byte[nonce.Length + cipher.Length + tag.Length];
        nonce.CopyTo(combined, 0);
        cipher.CopyTo(combined, nonce.Length);
        tag.CopyTo(combined, nonce.Length + cipher.Length);
        return new SettingsArchive.ArchiveSecrets
        {
            Rounds = Rounds,
            Salt = Convert.ToBase64String(salt),
            Sealed = Convert.ToBase64String(combined),
        };
    }

    /// <summary>解开；密码不对、文件被改过（包括服务地址）都返回 null。</summary>
    public static Dictionary<string, string>? Unseal(
        SettingsArchive.ArchiveSecrets sealedSecrets,
        string password,
        IReadOnlyList<SettingsArchive.ArchiveService> services)
    {
        try
        {
            if (!string.Equals(sealedSecrets.Kdf, Algorithm, StringComparison.OrdinalIgnoreCase) ||
                sealedSecrets.Rounds is < 1 or > AcceptedMaxRounds ||
                sealedSecrets.Salt is null ||
                sealedSecrets.Sealed is null)
            {
                return null;
            }

            var salt = Convert.FromBase64String(sealedSecrets.Salt);
            if (salt.Length is < MinSaltBytes or > MaxSaltBytes)
            {
                return null;
            }

            var combined = Convert.FromBase64String(sealedSecrets.Sealed);
            if (combined.Length < 12 + 16 + 1)
            {
                return null;
            }

            var nonce = combined.AsSpan(0, 12);
            var tag = combined.AsSpan(combined.Length - 16, 16);
            var cipher = combined.AsSpan(12, combined.Length - 12 - 16);
            var plain = new byte[cipher.Length];
            using (var aes = new AesGcm(Key(password, salt, sealedSecrets.Rounds), 16))
            {
                aes.Decrypt(nonce, cipher, tag, plain, Routing(services));
            }

            return JsonSerializer.Deserialize(
                plain, ArchiveCryptoJsonContext.Default.DictionaryStringString);
        }
        catch
        {
            return null;
        }
    }

    /// <summary>附加校验数据：每个服务往哪发请求（写法不随系统版本变）。</summary>
    public static byte[] Routing(IReadOnlyList<SettingsArchive.ArchiveService> services)
    {
        var builder = new StringBuilder();
        foreach (var service in services)
        {
            foreach (var field in new[]
                     {
                         service.Id ?? string.Empty,
                         service.Kind ?? string.Empty,
                         service.AiProtocol ?? string.Empty,
                         service.BaseUrl ?? string.Empty,
                         service.UsesDeepLX == true ? "1" : "0",
                     })
            {
                builder.Append(Encoding.UTF8.GetByteCount(field)).Append(':').Append(field);
            }
        }

        return Encoding.UTF8.GetBytes(builder.ToString());
    }

    public static byte[] Key(string password, byte[] salt, int rounds)
        => Rfc2898DeriveBytes.Pbkdf2(
            password.Normalize(NormalizationForm.FormC), salt, rounds, HashAlgorithmName.SHA256, 32);
}

[System.Text.Json.Serialization.JsonSerializable(typeof(Dictionary<string, string>))]
internal sealed partial class ArchiveCryptoJsonContext : System.Text.Json.Serialization.JsonSerializerContext
{
}
