// 设置 › 通用「同步」里「连接服务器…」的对话框（PLAN-v19 V5，照 mac Settings/SyncServerForm.swift）：填 WebDAV 服务器的地址、
// 文件夹、用户名和密码。「测试连接」看连不连得上、能不能写，结果写在对话框里、不关；「连接」先看服务器上那个文件夹
// （SyncServer.InspectAsync），已经有别的电脑在同步就在同一个对话框里换成问句（ContentDialog 不能再叠一个），再开
// （Syncer.EnableServerAsync）。网络都在线程池上。两个按钮都先 args.Cancel = true：对话框只在连成了（Hide）或者点「取消」时关，
// 正在测试 / 连接时也关不掉。
using KittyTools.Core.Notes;
using KittyTools.Core.Sync;
using KittyTools.Infrastructure;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace KittyTools;

internal sealed partial class SettingsWindow
{
    private const string SyncServerExplanation =
        "文件夹没有的话连接时新建，每台电脑填同一个。密码存在这台电脑的凭据管理器里；有的服务要在网页上另外生成给第三方应用用的密码。";

    /// <summary>UI 截图自检：对话框打开后填的东西和要按的按钮（"test" / "connect" / "join" / 别的 = 只填不按）。</summary>
    internal sealed record SyncServerProbeFill(string Address, string Folder, string User, string Password, string Action);

    private SyncServerProbeFill? _syncServerFill;

    /// <summary>UI 截图自检（只在测试档）：弹「连接服务器…」对话框，fill 不是 null 就填好、按一下；关它用 CloseDialogsForProbe。</summary>
    internal void OpenSyncServerForProbe(SyncServerProbeFill? fill)
    {
        _syncServerFill = fill;
        _ = ConnectSyncServerAsync();
    }

    /// <summary>UI 截图自检：页面滚到标题是 title 的那一节（「同步」）的顶上。</summary>
    internal void ScrollToSectionForProbe(string title)
    {
        _scroll.UpdateLayout();
        foreach (var child in _content.Children)
        {
            if (child is FrameworkElement element && Texts(element).Contains(title))
            {
                var top = element.TransformToVisual((UIElement)_scroll.Content).TransformPoint(default).Y;
                _scroll.ChangeView(null, Math.Max(0, top - 8), null, disableAnimation: true);
                return;
            }
        }

        static IEnumerable<string> Texts(DependencyObject node)
        {
            if (node is TextBlock block)
            {
                yield return block.Text;
            }

            for (var index = 0; index < Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChildrenCount(node); index++)
            {
                foreach (var text in Texts(Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChild(node, index)))
                {
                    yield return text;
                }
            }
        }
    }

    private async Task ConnectSyncServerAsync()
    {
        if (Syncer.Instance is not { } syncer)
        {
            return;
        }

        try
        {
            var address = new TextBox { Header = "服务器地址", PlaceholderText = "https://dav.example.com/dav/" };
            var folder = new TextBox { Header = "文件夹", Text = "Kitty Tools 同步", PlaceholderText = "Kitty Tools 同步" };
            var user = new TextBox { Header = "用户名" };
            var password = new PasswordBox { Header = "密码", MaxLength = 256 };
            var note = new TextBlock
            {
                Text = SyncServerExplanation,
                FontSize = 12,
                TextWrapping = TextWrapping.Wrap,
                Foreground = Theme.SecondaryText(),
            };
            var insecure = new TextBlock
            {
                Text = "这个地址没加密（http），密码和同步的内容在网上都是明文的",
                FontSize = 12,
                TextWrapping = TextWrapping.Wrap,
                Foreground = Theme.Caution(),
                Visibility = Visibility.Collapsed,
            };
            var spinner = new ProgressRing
            {
                IsActive = false,
                Width = 16,
                Height = 16,
                Visibility = Visibility.Collapsed,
                VerticalAlignment = VerticalAlignment.Top,
            };
            var line = new Grid { ColumnSpacing = 8 };
            line.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            line.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            line.Children.Add(spinner);
            Grid.SetColumn(note, 1);
            line.Children.Add(note);
            var form = new StackPanel { Spacing = 10, Width = 400 };
            form.Children.Add(address);
            form.Children.Add(folder);
            form.Children.Add(user);
            form.Children.Add(password);
            form.Children.Add(line);
            form.Children.Add(insecure);

            const string title = "连接 WebDAV 服务器";
            var dialog = new ContentDialog
            {
                RequestedTheme = Theme.ElementTheme,
                Title = title,
                Content = form,
                PrimaryButtonText = "连接",
                SecondaryButtonText = "测试连接",
                CloseButtonText = "取消",
                DefaultButton = ContentDialogButton.Primary,
                XamlRoot = _shell.XamlRoot,
            };

            var working = false;
            WebDavAccount? joining = null;

            // 填的样子拼成的账号：地址不像（不是 http(s)、没有主机）、没填用户名或密码时是 null
            WebDavAccount? Account()
            {
                var name = user.Text.Trim();
                return name.Length == 0 || password.Password.Length == 0 ||
                       WebDav.Folder(address.Text, folder.Text) is not { } url
                    ? null
                    : new WebDavAccount(url, name, password.Password);
            }

            void Refresh()
            {
                var ready = !working && Account() is not null;
                dialog.IsPrimaryButtonEnabled = joining is not null ? !working : ready;
                dialog.IsSecondaryButtonEnabled = joining is null && ready;
                foreach (var field in new Control[] { address, folder, user, password })
                {
                    field.IsEnabled = !working;
                }

                spinner.IsActive = working;
                spinner.Visibility = working ? Visibility.Visible : Visibility.Collapsed;
                // 转圈藏着时不留列间距，说明文和下面的橙字左边对齐
                line.ColumnSpacing = working ? 8 : 0;
                insecure.Visibility = address.Text.Trim().StartsWith("http://", StringComparison.OrdinalIgnoreCase)
                    ? Visibility.Visible
                    : Visibility.Collapsed;
            }

            void Say(string text, bool problem)
            {
                note.Text = text;
                note.Foreground = problem ? Theme.Caution() : Theme.SecondaryText();
            }

            void Edited()
            {
                Say(SyncServerExplanation, problem: false);
                Refresh();
            }

            // 问「合在一起？」之后没连成：换回表单，说为什么
            void BackToForm(string problem)
            {
                joining = null;
                dialog.Title = title;
                dialog.Content = form;
                dialog.PrimaryButtonText = "连接";
                dialog.SecondaryButtonText = "测试连接";
                Say(problem, problem: true);
                Refresh();
            }

            async Task TestAsync()
            {
                if (Account() is not { } account)
                {
                    return;
                }

                working = true;
                Refresh();
                var dav = syncer.Dav(account);
                var (test, failure) = await Task.Run(() => SyncServer.TestAsync(dav));
                working = false;
                Say(
                    test switch
                    {
                        ServerTest.Ready => "连上了，能读能写",
                        ServerTest.Missing => "连上了；服务器上还没有这个文件夹，连接时会新建",
                        _ => failure?.Message ?? "没连上",
                    },
                    problem: test == ServerTest.Failed);
                Refresh();
            }

            async Task EnableAsync(WebDavAccount account)
            {
                working = true;
                Refresh();
                var problem = await syncer.EnableServerAsync(account);
                working = false;
                if (problem is not null)
                {
                    BackToForm(problem);
                    return;
                }

                _ = syncer.RoundAsync();
                BuildPage("general");
                dialog.Hide();
            }

            // 先看服务器上那个文件夹：有别的电脑在同步（格式不比这一版新）就先问，不然直接开
            async Task ConnectAsync()
            {
                if (Account() is not { } account)
                {
                    return;
                }

                working = true;
                Refresh();
                var dav = syncer.Dav(account);
                var device = SyncDevice.Instance?.Id ?? string.Empty;
                var seen = await Task.Run(() => SyncServer.InspectAsync(dav, device));
                working = false;
                if (seen.Failure is { } failure)
                {
                    Say(failure.Message, problem: true);
                    Refresh();
                    return;
                }

                if (seen.Marker is { } marker && marker.Format <= NoteSyncFolder.Format && seen.Devices > 0)
                {
                    joining = account;
                    dialog.Title = "和服务器上这个文件夹里已经在同步的电脑合在一起？";
                    dialog.Content = new TextBlock
                    {
                        Text = (seen.Notes > 0
                            ? $"这个文件夹里已经有 {seen.Devices} 台电脑在同步，有 {seen.Notes} 条便签（含「最近删除」里的）。"
                            : $"这个文件夹里已经有 {seen.Devices} 台电脑在同步。") + JoinNote,
                        TextWrapping = TextWrapping.Wrap,
                        MaxWidth = 420,
                        HorizontalAlignment = HorizontalAlignment.Left,
                    };
                    dialog.PrimaryButtonText = "合在一起";
                    dialog.SecondaryButtonText = string.Empty;
                    Refresh();
                    return;
                }

                await EnableAsync(account);
            }

            address.TextChanged += (_, _) => Edited();
            folder.TextChanged += (_, _) => Edited();
            user.TextChanged += (_, _) => Edited();
            password.PasswordChanged += (_, _) => Edited();
            dialog.PrimaryButtonClick += (sender, args) =>
            {
                args.Cancel = true;
                if (!working)
                {
                    _ = joining is { } pending ? EnableAsync(pending) : ConnectAsync();
                }
            };
            dialog.SecondaryButtonClick += (sender, args) =>
            {
                args.Cancel = true;
                if (!working)
                {
                    _ = TestAsync();
                }
            };
            dialog.Closing += (_, args) =>
            {
                // 正在测试 / 连接时不让关（连到一半关掉，设置页会停在旧的样子）
                if (working)
                {
                    args.Cancel = true;
                }
            };
            Refresh();
            if (Paths.IsTestProfile && _syncServerFill is { } fill)
            {
                // UI 截图自检（PLAN-v19 第 7 条）：填好再按一下「测试连接」「连接」，或连上「合在一起」（只对本机的测试服务器）
                _syncServerFill = null;
                address.Text = fill.Address;
                folder.Text = fill.Folder;
                user.Text = fill.User;
                password.Password = fill.Password;
                DispatcherQueue.TryEnqueue(async () =>
                {
                    // 对话框还没排版时改 Text 不一定发 TextChanged：按钮、http 橙字按填好的样子刷一遍
                    Refresh();
                    switch (fill.Action)
                    {
                        case "test":
                            await TestAsync();
                            break;
                        case "connect":
                            await ConnectAsync();
                            break;
                        case "join":
                            await ConnectAsync();
                            if (joining is { } pending)
                            {
                                await EnableAsync(pending);
                            }

                            break;
                    }
                });
            }

            await dialog.ShowAsync();
        }
        catch (Exception ex)
        {
            Log.Error("settings.sync-server-failed", ex);
        }
    }
}
