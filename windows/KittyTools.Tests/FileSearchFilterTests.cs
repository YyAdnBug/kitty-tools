// 文件搜索的路径过滤和查询词清洗（PLAN-v25 F3、F5、F6；Core FileSearchFilter）。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class FileSearchFilterTests
{
    [TestMethod]
    public void KeepsOrdinaryUserFilesAnywhere()
    {
        Assert.IsFalse(FileSearchFilter.IsExcluded(@"C:\Users\YY\Documents\季度报告.docx", "C:"));
        Assert.IsFalse(FileSearchFilter.IsExcluded(@"D:\工作\2025\季度报告.docx", "C:"));
        Assert.IsFalse(FileSearchFilter.IsExcluded(@"C:\Users\YY\OneDrive - 公司\合同.pdf", @"C:\"));
        Assert.IsFalse(FileSearchFilter.IsExcluded(@"\\nas\share\照片\1.jpg", "C:"));
    }

    [TestMethod]
    public void DropsSystemAndAppDataFolders()
    {
        Assert.IsTrue(FileSearchFilter.IsExcluded(@"C:\Users\YY\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\微信.lnk", "C:"));
        Assert.IsTrue(FileSearchFilter.IsExcluded(@"C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Excel.lnk", "C:"));
        Assert.IsTrue(FileSearchFilter.IsExcluded(@"C:\Windows\System32\notepad.exe", "C:"));
        Assert.IsTrue(FileSearchFilter.IsExcluded(@"D:\$Recycle.Bin\S-1-5-21\报告.docx", "C:"));
        Assert.IsTrue(FileSearchFilter.IsExcluded(@"E:\System Volume Information\x.dat", "C:"));
        Assert.IsTrue(FileSearchFilter.IsExcluded(@"D:\Program Files\App\readme.txt", "C:"));
        Assert.IsTrue(FileSearchFilter.IsExcluded(@"c:\program files (x86)\App\readme.txt", "C:"));
    }

    [TestMethod]
    public void SystemRootFoldersOnlyCountOnTheSystemDrive()
    {
        // D:\Windows 是用户自己的文件夹（系统装在 C 上）
        Assert.IsFalse(FileSearchFilter.IsExcluded(@"D:\Windows\报告.docx", "C:"));
        Assert.IsTrue(FileSearchFilter.IsExcluded(@"D:\Windows\报告.docx", "D:"));
        // 不在盘根下的 Windows 文件夹不算
        Assert.IsFalse(FileSearchFilter.IsExcluded(@"C:\Users\YY\Documents\Windows\笔记.txt", "C:"));
    }

    [TestMethod]
    public void DropsDependencyAndHiddenFoldersButNotTheFolderItself()
    {
        Assert.IsTrue(FileSearchFilter.IsExcluded(@"D:\code\app\node_modules\lodash\readme.md", "C:"));
        Assert.IsTrue(FileSearchFilter.IsExcluded(@"D:\code\app\.git\config", "C:"));
        Assert.IsTrue(FileSearchFilter.IsExcluded(@"D:\code\app\Build\out.txt", "C:"));
        // 文件夹本身（最后一段）照样搜得到；点开头的文件本身也是
        Assert.IsFalse(FileSearchFilter.IsExcluded(@"D:\code\app\node_modules", "C:"));
        Assert.IsFalse(FileSearchFilter.IsExcluded(@"D:\code\app\.gitignore", "C:"));
        // 盘根本身不排除（Everything 的「盘」结果调用方另外丢）
        Assert.IsFalse(FileSearchFilter.IsExcluded(@"D:\", "C:"));
        Assert.IsTrue(FileSearchFilter.IsExcluded("  ", "C:"));
    }

    [TestMethod]
    public void SkipsFoldersByName()
    {
        Assert.IsTrue(FileSearchFilter.SkipsFolder("node_modules"));
        Assert.IsTrue(FileSearchFilter.SkipsFolder(".vscode"));
        Assert.IsTrue(FileSearchFilter.SkipsFolder("APPDATA"));
        Assert.IsFalse(FileSearchFilter.SkipsFolder("工作"));
    }

    [TestMethod]
    public void TokensDropCharactersNoFileNameCanHave()
    {
        CollectionAssert.AreEqual(new[] { "季度", "报告" }, FileSearchFilter.Tokens("  季度   报告 "));
        CollectionAssert.AreEqual(new[] { "ab", "xy" }, FileSearchFilter.Tokens("a:b x*y"));
        CollectionAssert.AreEqual(new[] { "name" }, FileSearchFilter.Tokens("\"name\" ? |"));
        CollectionAssert.AreEqual(new[] { "a", "b", "c", "d" }, FileSearchFilter.Tokens("a b c d e"));
        Assert.AreEqual(0, FileSearchFilter.Tokens(@"\ / : * ? "" < > |").Count);
        // 文件名里能有的照留（空格以外的标点、括号、百分号、单引号）
        CollectionAssert.AreEqual(new[] { "报告(终版)&v2_[1]'s%.txt" }, FileSearchFilter.Tokens("报告(终版)&v2_[1]'s%.txt"));
    }

    [TestMethod]
    public void TopmostFoldersDropsNestedAndDuplicateRoots()
    {
        var roots = FileSearchFilter.TopmostFolders(new[]
        {
            @"C:\Users\YY\OneDrive\Desktop",
            @"C:\Users\YY\Downloads\",
            @"C:\Users\YY\OneDrive",
            @"c:\users\yy\downloads",
            @"C:\Users\YY\OneDriveBackup",
            "",
        });
        CollectionAssert.AreEqual(new[] { @"C:\Users\YY\Downloads", @"C:\Users\YY\OneDrive", @"C:\Users\YY\OneDriveBackup" }, roots);
    }

    [TestMethod]
    public void CrawlUrlEndsWithBackslash()
    {
        Assert.AreEqual(@"file:///D:\", FileSearchFilter.CrawlUrl(@"D:\"));
        Assert.AreEqual(@"file:///D:\Work\", FileSearchFilter.CrawlUrl(@"D:\Work"));
        Assert.AreEqual(@"file:///C:\Users\YY\Desktop\", FileSearchFilter.CrawlUrl("C:/Users/YY/Desktop/"));
    }
}
