// 设置 › 翻译（照 mac Settings/TranslateTab + TranslateServiceDetail，PLAN-v9-translate 8e）：
// 分节 语言（第一 / 第二语言，选成同一种就互换）｜译文字号（滑块 + 一张真卡片实时预览）｜查词｜行为（浮窗位置、接行、复制即译、自动复制、
// 截图翻译时复制识别出的原文、记录翻译历史、历史最多保留、导出和清空、浮窗里的按键）｜翻译服务（一行一个，点一行进详情，右键上移下移删除；
// 「添加服务」：没加的内置服务、「AI 服务」子菜单里 9 家预设 + 自定义 / Azure，加完直接进详情）。
// 服务详情（D3）是这一页里推进去的子页（「‹ 翻译」回列表），改了就存，没有「保存」：启用、各服务自己的选项、密钥（预先填好，改了就存）、
// 模型列表（地址和 Key 齐了自动取 /models，打字时下拉匹配的，↻ 重取）、测试连接（「Hello, world」英译中，成功自动启用）、删除自建 AI 服务。
using KittyTools.Core;
using KittyTools.Infrastructure;
using KittyTools.Ui;
using Microsoft.UI;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;

namespace KittyTools;

internal sealed partial class SettingsWindow
{
    private const string FontSample = "SwiftUI 提供了声明 App 界面所需的视图、控件和布局结构。";

    /// <summary>翻译页里推进去的服务详情（服务 id）；null = 列表。</summary>
    private string? _serviceDetail;

    /// <summary>刚从「添加服务」新建的 AI 服务：详情页把光标放进 API Key。</summary>
    private bool _focusServiceKey;

    private void BuildTranslate()
    {
        var store = TranslateServiceStore.Instance;
        if (store is null)
        {
            _content.Children.Add(Header("翻译", "语言、翻译服务与密钥、历史"));
            _content.Children.Add(new TextBlock { Text = "翻译服务还没准备好。", Foreground = Theme.SecondaryText() });
            return;
        }

        if (_serviceDetail is { } detail && store.Find(detail) is { } service)
        {
            BuildServiceDetail(store, service);
            return;
        }

        _serviceDetail = null;
        Log.Info("settings.translate.build-start");
        var settings = SettingsService.Current;
        _content.Children.Add(Header("翻译", "语言、翻译服务与密钥、历史"));
        // 2026-10-29 布局对齐 mac：第一行「启用翻译」，组的说明写在组下面；历史的保留、导出清空和按键那几行功能关着也能用。
        AddFeatureToggle(Feature.Translate);

        // ---- 语言
        _content.Children.Add(SettingsUi.Section("语言"));
        var langs = Enum.GetValues<Lang>();
        var titles = langs.Select(lang => lang.Title()).ToArray();
        var (first, second) = store.Languages;
        AddCombo("第一语言", string.Empty, titles, Array.IndexOf(langs, first), index => SetLanguage(isFirst: true, langs[index]));
        AddCombo("第二语言", string.Empty, titles, Array.IndexOf(langs, second), index => SetLanguage(isFirst: false, langs[index]));
        _content.Children.Add(SettingsUi.Footnote(
            "目标语言选「自动」时：原文是第一语言就译成第二语言，否则译成第一语言（简繁中文算同一种）。源语言和目标语言在翻译浮窗顶部切换，会一直记住。"));

        // ---- 译文字号：滑块 + 一张真卡片（第一个服务）跟着变
        _content.Children.Add(SettingsUi.Section("译文字号"));
        var preview = new TranslateCardView(store.Services.FirstOrDefault() ?? TranslateServiceStore.Builtin(TranslateKinds.Zhipu),
            () => { }, () => { }, () => { }, () => { });
        preview.Root.IsHitTestVisible = false;
        AutomationProperties.SetAccessibilityView(preview.Root, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        void Preview(double scale) => preview.Update(
            new TranslateCard { Service = store.Services.FirstOrDefault() ?? TranslateServiceStore.Builtin(TranslateKinds.Zhipu), State = CardState.Done, Text = FontSample },
            0, scale, collapsed: false, copied: false, Lang.ZhHans);
        var percent = new TextBlock
        {
            Width = 44,
            TextAlignment = TextAlignment.Right,
            FontSize = 12,
            FontWeight = FontWeights.Medium,
            VerticalAlignment = VerticalAlignment.Center,
            Text = $"{settings.TranslateFontScale:P0}",
        };
        var slider = new Slider
        {
            Minimum = 0.8,
            Maximum = 1.6,
            StepFrequency = 0.1,
            SmallChange = 0.1,
            Value = settings.TranslateFontScale,
            Width = 220,
            VerticalAlignment = VerticalAlignment.Center,
        };
        AutomationProperties.SetName(slider, "译文字号");
        slider.ValueChanged += (_, args) =>
        {
            var scale = Math.Round(args.NewValue, 1);
            settings.TranslateFontScale = scale;
            SettingsService.Save();
            percent.Text = $"{scale:P0}";
            Preview(scale);
        };
        var sizeControls = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
        sizeControls.Children.Add(slider);
        sizeControls.Children.Add(percent);
        _content.Children.Add(SettingsUi.Card("大小", string.Empty, sizeControls));
        Preview(settings.TranslateFontScale);
        _content.Children.Add(preview.Root);

        // ---- 查词（系统词典那一项 Windows 不做：没有系统词典接口，PLAN-v3 §3.4）
        _content.Children.Add(SettingsUi.Section("查词"));
        AddToggle("查单个词时大模型按词典回答（读音、词性、例句）", string.Empty, settings.TranslateWordLookup, isOn =>
        {
            settings.TranslateWordLookup = isOn;
            SettingsService.Save();
        });
        _content.Children.Add(SettingsUi.Footnote("查单个词时不自动复制、不给「替换原文」。"));

        // ---- 行为
        _content.Children.Add(SettingsUi.Section("行为"));
        var positions = new[] { "top", "pointer", "last" };
        AddCombo("浮窗位置",
            "划词、截图翻译、复制即译时出现的位置：屏幕上方是鼠标所在屏幕的上方正中，跟随鼠标是光标旁边；输入翻译总在上次拖到的位置",
            new[] { "屏幕上方", "跟随鼠标", "上次位置" }, Math.Max(0, Array.IndexOf(positions, settings.TranslateWindowPosition)), index =>
            {
                settings.TranslateWindowPosition = positions[index];
                SettingsService.Save();
            });
        AddToggle("翻译前把同一段里的换行接起来（适合 PDF 复制的文字）", string.Empty, settings.TranslateJoinLines, isOn =>
        {
            settings.TranslateJoinLines = isOn;
            SettingsService.Save();
        });
        AddToggle("复制即译", "在别的程序里复制文字，浮窗自动弹出翻译（网址、路径和数字不翻）",
            settings.CopyTranslate, isOn =>
            {
                settings.CopyTranslate = isOn;
                SettingsService.Save();
                TranslateHost.ApplyCopyTranslate();
            });
        // 这几个开关只原地改受影响的那一行（说明 / 能不能点），不重建整页：重建时整页的开关都闪一下（2026-10-29 用户反馈）。
        static string CopyRecognizedNote(bool autoCopy) => autoCopy
            ? "识别出来就放进剪贴板；译文出来后，剪贴板换成译文（上面开着自动复制）"
            : "识别出来就放进剪贴板，Ctrl+V 能直接粘贴；关着时只记进剪贴板历史";
        Border? copyRecognizedCard = null;
        AddToggle("自动复制译文", "复制即译弹出的翻译不会自动复制，免得覆盖你刚复制的原文", settings.TranslateAutoCopy, isOn =>
        {
            settings.TranslateAutoCopy = isOn;
            SettingsService.Save();
            if (copyRecognizedCard is not null)
            {
                SettingsUi.SetDescription(copyRecognizedCard, CopyRecognizedNote(isOn));
            }
        });
        copyRecognizedCard = AddToggle("截图翻译时复制识别出的原文",
            CopyRecognizedNote(settings.TranslateAutoCopy),
            settings.TranslateCopyRecognized, isOn =>
            {
                settings.TranslateCopyRecognized = isOn;
                SettingsService.Save();
            });
        Border? limitCard = null;
        AddToggle("记录翻译历史", string.Empty, settings.TranslateHistoryEnabled, isOn =>
        {
            settings.TranslateHistoryEnabled = isOn;
            SettingsService.Save();
            if (limitCard is not null)
            {
                SettingsUi.SetEnabled(limitCard, isOn);
            }
        });
        var limits = new[] { 1000, 5000, 0 };
        limitCard = SettingsUi.Card("历史最多保留", string.Empty,
            SettingsUi.Combo(new[] { "1000 条", "5000 条", "不限" },
                Math.Max(0, Array.IndexOf(limits, settings.TranslateHistoryLimit)), index =>
                {
                    settings.TranslateHistoryLimit = limits[index];
                    SettingsService.Save();
                }, "历史最多保留"),
            enabled: settings.TranslateHistoryEnabled);
        _content.Children.Add(Ungated(limitCard));

        var exportMenu = new MenuFlyout();
        foreach (var (favoritesOnly, anki, title) in HistoryMenu.Exports)
        {
            var item = new MenuFlyoutItem { Text = title };
            item.Click += (_, _) => _ = HistoryMenu.ExportAsync(AppWindow.Id, favoritesOnly, anki);
            exportMenu.Items.Add(item);
        }

        var export = new DropDownButton { Content = "导出…", Flyout = exportMenu };
        // 关着「记录翻译历史」也能清（旧记录还在）；和浮窗「⋯」菜单同一个确认框、同一句结果。
        var clear = new Button { Content = "清空翻译历史…", Foreground = Theme.Critical() };
        clear.Click += (_, _) => _ = HistoryMenu.ConfirmClearAsync(_content.XamlRoot);
        var historyButtons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        historyButtons.Children.Add(export);
        historyButtons.Children.Add(clear);
        _content.Children.Add(Ungated(SettingsUi.Card("导出和清空", string.Empty, historyButtons)));

        Ungated(AddShortcutsRow("translate", "翻译浮窗里的按键",
            "Enter 翻译，Ctrl+R 重新翻译，Ctrl+1–9 复制第 1–9 个结果，Ctrl+H 翻译历史；划词来的翻译可以「替换原文」"));
        _content.Children.Add(Ungated(SettingsUi.Footnote("收藏的记录不算在保留条数里、永不清理。")));

        // ---- 翻译服务
        _content.Children.Add(SettingsUi.Section("翻译服务"));
        if (TranslateServiceStore.BuiltinZhipuKey is null)
        {
            _content.Children.Add(new TextBlock
            {
                Text = "这个构建没有内置智谱 key：要使用免费的智谱，请点进去填自己的 API Key。",
                Foreground = Theme.SecondaryText(),
                TextWrapping = TextWrapping.Wrap,
                FontSize = 12,
            });
        }

        var services = store.Services.ToList();
        for (var index = 0; index < services.Count; index++)
        {
            _content.Children.Add(ServiceRow(store, services[index], index, services.Count));
        }

        _content.Children.Add(AddServiceButton(store));
        _content.Children.Add(SettingsUi.Footnote(
            "结果按这个顺序显示；排在最前、翻译成功的那个服务的结果写入历史、用于自动复制和收藏。点一行进入设置，右键可以上移、下移和删除。" +
            "删掉的内置服务可以从「添加服务」加回来，密钥还在。"));
        Log.Info($"settings.translate.build-done services={store.Services.Count}");
    }

    /// <summary>第一 / 第二语言选成同一种（简繁也算）就互换，免得「自动」变成中译中。</summary>
    private void SetLanguage(bool isFirst, Lang lang)
    {
        var settings = SettingsService.Current;
        var (first, second) = Langs.Pair(settings.TranslateFirstLanguage, settings.TranslateSecondLanguage);
        var other = isFirst ? second : first;
        var old = isFirst ? first : second;
        if (lang.SameLanguage(other))
        {
            other = old;
        }

        settings.TranslateFirstLanguage = (isFirst ? lang : other).Code();
        settings.TranslateSecondLanguage = (isFirst ? other : lang).Code();
        SettingsService.Save();
        TranslateHost.MarkLanguagesChanged();
        BuildPage("translate");
    }

    /// <summary>
    /// 一个服务一行（mac ServiceListRow）：服务图标 24、名称 + 状态、启用开关、›；点一行进详情，右键 设置… / 上移 / 下移 / 删除。
    /// 内置的直接删（「添加服务」里能加回来，密钥留着），自建的 AI 服务先确认、连密钥一起删。
    /// ponytail: 只能右键上移 / 下移，没做 mac 那样的拖动排序（卡片列表要换成可拖的 ListView）；服务多了再做。
    /// </summary>
    private Border ServiceRow(TranslateServiceStore store, TranslateServiceConfig service, int index, int count)
    {
        var (status, problem) = ServiceStatus(store, service);
        var controls = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12, VerticalAlignment = VerticalAlignment.Center };
        Border? statusCard = null;
        controls.Children.Add(SettingsUi.Toggle(service.Enabled, isOn =>
        {
            service.Enabled = isOn;
            store.Save();
            // 只改这一行的状态说明（以前整页重建，别的服务的开关跟着闪）。
            if (statusCard is not null)
            {
                var (text, bad) = ServiceStatus(store, service);
                SettingsUi.SetDescription(statusCard, text, bad);
            }
        }, $"启用「{service.Name}」"));
        controls.Children.Add(new FontIcon
        {
            Glyph = Glyphs.ChevronRight,
            FontSize = 12,
            Foreground = Theme.SecondaryText(),
            VerticalAlignment = VerticalAlignment.Center,
        });
        var card = SettingsUi.Card(
            service.Name,
            status,
            controls,
            () => OpenServiceDetail(service.Id),
            leading: ServiceTile.Create(service, 24),
            problem: problem);
        statusCard = card;

        var menu = new MenuFlyout();
        void Add(string text, bool enabled, Action action)
        {
            var item = new MenuFlyoutItem { Text = text, IsEnabled = enabled };
            item.Click += (_, _) => action();
            menu.Items.Add(item);
        }

        void Move(int offset)
        {
            store.Services.RemoveAt(index);
            store.Services.Insert(index + offset, service);
            store.Save();
            BuildPage("translate");
        }

        Add("设置…", true, () => OpenServiceDetail(service.Id));
        menu.Items.Add(new MenuFlyoutSeparator());
        Add("上移", index > 0, () => Move(-1));
        Add("下移", index < count - 1, () => Move(1));
        menu.Items.Add(new MenuFlyoutSeparator());
        Add(service.Kind == TranslateKinds.Ai ? "删除…" : "删除", true, () => _ = RemoveServiceAsync(store, service));
        card.ContextFlyout = menu;
        return card;
    }

    private void OpenServiceDetail(string id, bool focusKey = false)
    {
        _serviceDetail = id;
        _focusServiceKey = focusKey;
        BuildPage("translate");
        _scroll.ChangeView(null, 0, null, disableAnimation: true);
    }

    private void CloseServiceDetail()
    {
        _serviceDetail = null;
        BuildPage("translate");
    }

    /// <summary>内置的直接删；自建 AI 先确认（连凭据管理器里的密钥一起删）。</summary>
    private async Task RemoveServiceAsync(TranslateServiceStore store, TranslateServiceConfig service)
    {
        if (service.Kind == TranslateKinds.Ai)
        {
            var dialog = new ContentDialog
            {
                RequestedTheme = Theme.ElementTheme,
                Title = $"删除「{service.Name}」？",
                Content = "会同时删除它保存在凭据管理器里的密钥。",
                PrimaryButtonText = "删除",
                CloseButtonText = "取消",
                DefaultButton = ContentDialogButton.Close,
                XamlRoot = _content.XamlRoot,
            };
            if (await dialog.ShowAsync() != ContentDialogResult.Primary)
            {
                return;
            }
        }

        store.Remove(service.Id);
        _serviceDetail = null;
        BuildPage("translate");
    }

    /// <summary>
    /// 「添加服务」（mac「+」菜单）：还没加的内置服务（带图标）｜「AI 服务」子菜单（9 家预设 + 自定义 / Azure）。
    /// 内置的加回来直接启用（密钥是删之前留下的）；AI 服务等测试连接成功再自动启用。加完推进详情（AI 服务光标落在 API Key）。
    /// </summary>
    private Button AddServiceButton(TranslateServiceStore store)
    {
        var menu = new MenuFlyout();
        foreach (var kind in store.MissingBuiltins)
        {
            var item = new MenuFlyoutItem { Text = TranslateKinds.DefaultName(kind), Icon = MenuLogo(TranslateServiceStore.Builtin(kind)) };
            item.Click += (_, _) =>
            {
                var service = store.AddBuiltin(kind);
                service.Enabled = true;
                store.Save();
                OpenServiceDetail(service.Id);
            };
            menu.Items.Add(item);
        }

        if (menu.Items.Count > 0)
        {
            menu.Items.Add(new MenuFlyoutSeparator());
        }

        var ai = new MenuFlyoutSubItem { Text = "AI 服务" };
        foreach (var preset in TranslatePresets.Ai)
        {
            var item = new MenuFlyoutItem { Text = preset.Name, Icon = MenuLogo(preset.Create()) };
            item.Click += (_, _) => OpenServiceDetail(store.AddAi(preset).Id, focusKey: true);
            ai.Items.Add(item);
        }

        ai.Items.Add(new MenuFlyoutSeparator());
        var custom = new MenuFlyoutItem { Text = "自定义（OpenAI 兼容）…" };
        custom.Click += (_, _) => OpenServiceDetail(store.AddCustomAi().Id, focusKey: true);
        ai.Items.Add(custom);
        var azure = new MenuFlyoutItem { Text = "Azure OpenAI…" };
        azure.Click += (_, _) =>
        {
            var service = store.AddCustomAi();
            service.Name = "Azure OpenAI";
            service.Protocol = "azure";
            store.Save();
            OpenServiceDetail(service.Id, focusKey: true);
        };
        ai.Items.Add(azure);
        menu.Items.Add(ai);
        return new Button { Content = "＋ 添加服务", Flyout = menu };
    }

    /// <summary>菜单项上的服务 logo（没有官方 logo 的就不放图标）。</summary>
    private static IconElement? MenuLogo(TranslateServiceConfig service)
        => ServiceBadge.Logo(service.Kind, service.Protocol, service.BaseUrl, service.Name) is { } logo
            ? new ImageIcon { Source = new BitmapImage(new Uri($"ms-appx:///Resources/ServiceLogo/{logo}.png")) }
            : null;

    /// <summary>服务行和详情页头的状态字（mac settingsStatus）：缺了要填的、且服务开着时算问题（橙字）。</summary>
    private static (string Text, bool Problem) ServiceStatus(TranslateServiceStore store, TranslateServiceConfig service)
    {
        var (text, missing) = service.Kind switch
        {
            TranslateKinds.Zhipu => store.Secret(service) is null && TranslateServiceStore.BuiltinZhipuKey is null
                ? ("未填密钥", true)
                : (TranslatePresets.ZhipuModel(service.Model), false),
            TranslateKinds.Ai => AiProviderStatus(service),
            TranslateKinds.DeepL => service.UsesDeepLX == true
                ? string.IsNullOrWhiteSpace(service.BaseUrl) ? ("未填 DeepLX 地址", true) : ("DeepLX（自建）", false)
                : store.Secret(service) is null ? ("未填密钥", true) : ("官方 API", false),
            TranslateKinds.Microsoft => (store.Secret(service) is null ? "免费 Edge 接口" : "Azure 翻译", false),
            _ => TranslateKinds.SecretFields(service.Kind).All(field => store.Secret(service, field) is not null)
                ? ("已填密钥", false)
                : ("未填密钥", true),
        };
        return (text, missing && service.Enabled);
    }

    private static (string, bool) AiProviderStatus(TranslateServiceConfig service)
    {
        var protocol = AiEndpoint.ParseProtocol(service.Protocol);
        if (protocol != AiProtocol.Anthropic && string.IsNullOrWhiteSpace(service.BaseUrl))
        {
            return ("未填服务地址", true);
        }

        if (string.IsNullOrWhiteSpace(service.Model))
        {
            return ("未填模型", true);
        }

        return ($"{ProtocolTitle(protocol)} · {service.Model.Trim()}", false);
    }

    private static string ProtocolTitle(AiProtocol protocol) => protocol switch
    {
        AiProtocol.Azure => "Azure OpenAI",
        AiProtocol.Anthropic => "Anthropic",
        _ => "OpenAI 兼容",
    };

    // ---- 服务详情（子页）

    private void BuildServiceDetail(TranslateServiceStore store, TranslateServiceConfig service)
    {
        var back = new HyperlinkButton { Content = "‹ 翻译", Padding = new Thickness(0), Margin = new Thickness(0, 0, 0, 4) };
        back.Click += (_, _) => CloseServiceDetail();
        AutomationProperties.SetName(back, "返回翻译设置");
        _content.Children.Add(back);

        // 页头：40 的服务图标 + 名称 + 状态（改了就跟着变）
        var title = new TextBlock { Text = service.Name, FontSize = 24, FontWeight = FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis };
        var status = new TextBlock { FontSize = 12, TextWrapping = TextWrapping.Wrap };
        void RefreshStatus()
        {
            var (text, problem) = ServiceStatus(store, service);
            title.Text = service.Name;
            status.Text = text;
            status.Foreground = problem ? Theme.Caution() : Theme.SecondaryText();
        }

        var titles = new StackPanel { Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
        titles.Children.Add(title);
        titles.Children.Add(status);
        var header = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 14, Margin = new Thickness(0, 0, 0, 8) };
        header.Children.Add(ServiceTile.Create(service, 40));
        header.Children.Add(titles);
        _content.Children.Add(header);
        RefreshStatus();

        void Save()
        {
            store.Save();
            RefreshStatus();
        }

        // ---- 启用 + 各服务自己的选项
        var enabled = SettingsUi.Toggle(service.Enabled, isOn =>
        {
            service.Enabled = isOn;
            Save();
        }, "启用");
        _content.Children.Add(SettingsUi.Card("启用", string.Empty, enabled));

        AutoSuggestBox? modelBox = null;
        var models = new List<string>();
        Button? refresh = null;
        ProgressRing? fetching = null;
        DispatcherQueueTimerHolder? autoFetch = null;
        PasswordBox? apiKey = null;

        switch (service.Kind)
        {
            case TranslateKinds.Zhipu:
                var zhipuModels = new[] { "glm-4-flash", "glm-4.7-flash" };
                _content.Children.Add(SettingsUi.Card("模型", string.Empty,
                    SettingsUi.Combo(zhipuModels, Array.IndexOf(zhipuModels, TranslatePresets.ZhipuModel(service.Model)), index =>
                    {
                        service.Model = zhipuModels[index];
                        Save();
                    }, "模型")));
                break;
            case TranslateKinds.Ai:
                var name = Field(service.Name, "名称", text =>
                {
                    if (text.Trim().Length > 0)
                    {
                        service.Name = text.Trim();
                        Save();
                    }
                });
                _content.Children.Add(SettingsUi.Card("名称", string.Empty, name));
                var protocols = new[] { AiProtocol.OpenAi, AiProtocol.Azure, AiProtocol.Anthropic };
                var address = Field(service.BaseUrl ?? string.Empty, AddressHint(AiEndpoint.ParseProtocol(service.Protocol)), text =>
                {
                    service.BaseUrl = text.Trim();
                    Save();
                    autoFetch?.Restart();
                });
                _content.Children.Add(SettingsUi.Card("协议", string.Empty,
                    SettingsUi.Combo(protocols.Select(ProtocolTitle).ToArray(),
                        Array.IndexOf(protocols, AiEndpoint.ParseProtocol(service.Protocol)), index =>
                        {
                            service.Protocol = protocols[index].ToString().ToLowerInvariant();
                            address.PlaceholderText = AddressHint(protocols[index]);
                            Save();
                            autoFetch?.Restart();
                        }, "协议")));
                _content.Children.Add(SettingsUi.Card("服务地址", string.Empty, address));

                modelBox = new AutoSuggestBox
                {
                    Text = service.Model ?? string.Empty,
                    PlaceholderText = "如 gpt-4o-mini",
                    Width = 236,
                    VerticalAlignment = VerticalAlignment.Center,
                };
                AutomationProperties.SetName(modelBox, "模型");
                modelBox.TextChanged += (box, args) =>
                {
                    if (args.Reason == AutoSuggestionBoxTextChangeReason.UserInput)
                    {
                        box.ItemsSource = AiEndpoint.ModelSuggestions(models, box.Text);
                    }

                    service.Model = box.Text.Trim();
                    Save();
                };
                modelBox.GotFocus += (box, _) =>
                {
                    if (box is AutoSuggestBox suggest && models.Count > 0)
                    {
                        suggest.ItemsSource = AiEndpoint.ModelSuggestions(models, suggest.Text);
                        suggest.IsSuggestionListOpen = true;
                    }
                };
                fetching = new ProgressRing { Width = 16, Height = 16, IsActive = false, Visibility = Visibility.Collapsed };
                refresh = new Button
                {
                    Content = new FontIcon { Glyph = Glyphs.Refresh, FontSize = 13 },
                    Padding = new Thickness(6),
                    Background = new SolidColorBrush(Colors.Transparent),
                    BorderThickness = new Thickness(0),
                };
                ToolTipService.SetToolTip(refresh, "重新读取服务端的模型列表");
                AutomationProperties.SetName(refresh, "重新读取模型列表");
                var modelRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
                modelRow.Children.Add(modelBox);
                modelRow.Children.Add(refresh);
                modelRow.Children.Add(fetching);
                _content.Children.Add(SettingsUi.Card("模型", string.Empty, modelRow));
                break;
            case TranslateKinds.DeepL:
                var deepLx = Field(service.BaseUrl ?? string.Empty, "如 http://127.0.0.1:1188/translate", text =>
                {
                    service.BaseUrl = text.Trim();
                    Save();
                });
                var deepLxCard = SettingsUi.Card("DeepLX 地址", string.Empty, deepLx);
                deepLxCard.Visibility = service.UsesDeepLX == true ? Visibility.Visible : Visibility.Collapsed;
                _content.Children.Add(SettingsUi.Card("接口", string.Empty,
                    SettingsUi.Combo(new[] { "官方 API", "DeepLX（自建）" }, service.UsesDeepLX == true ? 1 : 0, index =>
                    {
                        service.UsesDeepLX = index == 1;
                        deepLxCard.Visibility = index == 1 ? Visibility.Visible : Visibility.Collapsed;
                        Save();
                    }, "接口")));
                _content.Children.Add(deepLxCard);
                break;
            case TranslateKinds.Microsoft:
                _content.Children.Add(SettingsUi.Card("区域", string.Empty, Field(service.Region ?? string.Empty, "填了 Key 才需要，如 eastasia", text =>
                {
                    service.Region = text.Trim().Length == 0 ? null : text.Trim();
                    Save();
                })));
                break;
        }

        // ---- 密钥：预先填好已存的（掩码显示），改了就存；清空就删掉
        _content.Children.Add(SettingsUi.Section("密钥"));
        foreach (var field in TranslateKinds.SecretFields(service.Kind))
        {
            var box = new PasswordBox
            {
                Password = store.Secret(service, field) ?? string.Empty,
                PlaceholderText = SecretPrompt(service.Kind),
                Width = 260,
                VerticalAlignment = VerticalAlignment.Center,
            };
            AutomationProperties.SetName(box, TranslateKinds.SecretLabel(service.Kind, field));
            box.PasswordChanged += (_, _) =>
            {
                var value = box.Password.Trim();
                store.SetSecret(service, value.Length == 0 ? null : value, field);
                RefreshStatus();
                autoFetch?.Restart();
            };
            _content.Children.Add(SettingsUi.Card(TranslateKinds.SecretLabel(service.Kind, field), string.Empty, box));
            apiKey ??= box;
        }

        _content.Children.Add(SettingsUi.Footnote("只存在这台电脑的凭据管理器里。"));

        // ---- 测试连接
        _content.Children.Add(SettingsUi.Section("测试"));
        var test = new Button { Content = "测试连接" };
        var busy = new ProgressRing { Width = 16, Height = 16, IsActive = false, Visibility = Visibility.Collapsed };
        var resultIcon = new FontIcon { FontSize = 13, Visibility = Visibility.Collapsed, VerticalAlignment = VerticalAlignment.Center };
        var resultText = new TextBlock
        {
            FontSize = 12,
            Foreground = Theme.SecondaryText(),
            TextWrapping = TextWrapping.Wrap,
            MaxWidth = 360,
            IsTextSelectionEnabled = true,
            VerticalAlignment = VerticalAlignment.Center,
        };
        void ShowResult(bool? ok, string text)
        {
            resultIcon.Visibility = ok is null ? Visibility.Collapsed : Visibility.Visible;
            resultIcon.Glyph = ok == true ? Glyphs.Check : Glyphs.Error;
            resultIcon.Foreground = ok == true
                ? Theme.Brush("SystemFillColorSuccessBrush", Theme.Argb(255, 15, 123, 15))
                : Theme.Critical();
            resultText.Text = text;
        }

        test.Click += async (_, _) =>
        {
            test.IsEnabled = false;
            busy.IsActive = true;
            busy.Visibility = Visibility.Visible;
            ShowResult(null, string.Empty);
            var (ok, text) = await TestServiceAsync(service);
            ShowResult(ok, text);
            // 新加的服务配好了就能用：测试成功时把启用打开。
            if (ok && !service.Enabled)
            {
                service.Enabled = true;
                enabled.IsOn = true;
                Save();
            }

            busy.IsActive = false;
            busy.Visibility = Visibility.Collapsed;
            test.IsEnabled = true;
        };
        var testRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        testRow.Children.Add(test);
        testRow.Children.Add(busy);
        testRow.Children.Add(resultIcon);
        testRow.Children.Add(resultText);
        _content.Children.Add(testRow);
        _content.Children.Add(SettingsUi.Footnote("用「Hello, world」做一次英译中。"));

        if (service.Kind == TranslateKinds.Ai)
        {
            var delete = new Button { Content = "删除…", Foreground = Theme.Critical(), Margin = new Thickness(0, 12, 0, 0) };
            delete.Click += (_, _) => _ = RemoveServiceAsync(store, service);
            _content.Children.Add(delete);
        }

        // ---- 模型列表：地址（Anthropic 可空）和 Key（本机 / 局域网不要）齐了就后台取一次，停手 0.6 s 再取；取不到不报错，点 ↻ 才报
        if (service.Kind == TranslateKinds.Ai && modelBox is not null && refresh is not null && fetching is not null)
        {
            var box = modelBox;
            var spinner = fetching;
            var button = refresh;
            async Task FetchAsync(bool quiet)
            {
                if (!CanFetchModels(store, service))
                {
                    if (!quiet)
                    {
                        ShowResult(false, "先填服务地址和 API Key");
                    }

                    return;
                }

                spinner.IsActive = true;
                spinner.Visibility = Visibility.Visible;
                button.IsEnabled = false;
                if (!quiet)
                {
                    ShowResult(null, string.Empty);
                }

                try
                {
                    var list = await FetchModelsAsync(store, service);
                    models.Clear();
                    models.AddRange(list);
                    if (!quiet)
                    {
                        ShowResult(list.Count > 0, list.Count > 0 ? $"找到 {list.Count} 个模型，在「模型」里打字时会列出来" : "服务端没有返回模型");
                    }
                }
                catch (Exception ex)
                {
                    if (!quiet)
                    {
                        ShowResult(false, ex.Message);
                    }
                }
                finally
                {
                    spinner.IsActive = false;
                    spinner.Visibility = Visibility.Collapsed;
                    button.IsEnabled = true;
                }
            }

            button.Click += (_, _) => _ = FetchAsync(quiet: false);
            var timer = new DispatcherQueueTimerHolder(_content.DispatcherQueue, TimeSpan.FromSeconds(0.6), () => _ = FetchAsync(quiet: true));
            autoFetch = timer;
            timer.Restart();
            box.Unloaded += (_, _) => timer.Stop();
        }

        if (_focusServiceKey && apiKey is not null)
        {
            _focusServiceKey = false;
            var focus = apiKey;
            DispatcherQueue.TryEnqueue(() => focus.Focus(FocusState.Programmatic));
        }
    }

    /// <summary>设置页里的一行输入框：改了就存（每个字都存，没有「保存」）。</summary>
    private static TextBox Field(string text, string placeholder, Action<string> changed)
    {
        var box = new TextBox { Text = text, PlaceholderText = placeholder, Width = 260, VerticalAlignment = VerticalAlignment.Center };
        box.TextChanged += (_, _) => changed(box.Text);
        return box;
    }

    private static string AddressHint(AiProtocol protocol) => protocol switch
    {
        AiProtocol.Azure => "https://<资源名>.openai.azure.com/openai/v1",
        AiProtocol.Anthropic => "留空即 https://api.anthropic.com",
        _ => "https://api.openai.com/v1 或本机 http://127.0.0.1:11434/v1",
    };

    /// <summary>密钥框的提示（mac SecretField.prompt）。</summary>
    private static string SecretPrompt(string kind) => kind switch
    {
        TranslateKinds.Zhipu => TranslateServiceStore.BuiltinZhipuKey is not null ? "留空使用内置免费额度" : string.Empty,
        TranslateKinds.Ai => "本机模型可留空",
        TranslateKinds.DeepL => "免费版以 :fx 结尾",
        TranslateKinds.Microsoft => "留空使用免费的 Edge 接口",
        _ => string.Empty,
    };

    private static bool CanFetchModels(TranslateServiceStore store, TranslateServiceConfig service)
    {
        var protocol = AiEndpoint.ParseProtocol(service.Protocol);
        return AiEndpoint.Resolve(service.BaseUrl, protocol) is { } url &&
               (store.Secret(service) is not null || AiEndpoint.IsLocalNetwork(url));
    }

    /// <summary>读服务端的模型列表（mac AIService.fetchModels）：15 秒超时。</summary>
    private static async Task<List<string>> FetchModelsAsync(TranslateServiceStore store, TranslateServiceConfig service)
    {
        var protocol = AiEndpoint.ParseProtocol(service.Protocol);
        if (AiEndpoint.Resolve(service.BaseUrl, protocol) is not { } chat || AiEndpoint.ModelsUrl(chat, protocol) is not { } url)
        {
            throw new TranslateError("服务地址不正确", TranslateErrorKind.Config);
        }

        var key = store.Secret(service) ?? string.Empty;
        var headers = new Dictionary<string, string>();
        switch (protocol)
        {
            case AiProtocol.Azure:
                headers["api-key"] = key;
                break;
            case AiProtocol.Anthropic:
                headers["x-api-key"] = key;
                headers["anthropic-version"] = "2023-06-01";
                break;
            default:
                if (key.Length > 0)
                {
                    headers["Authorization"] = "Bearer " + key;
                }

                break;
        }

        using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(15));
        return AiEndpoint.ParseModels(await TranslateHttp.GetTextAsync(url, headers, cts.Token));
    }

    /// <summary>测试连接（B14）：「Hello, world」英译中（两个词，开着查词也不会走单词模式），20 秒超时。</summary>
    private static async Task<(bool Ok, string Text)> TestServiceAsync(TranslateServiceConfig service)
    {
        try
        {
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(20));
            var request = new TranslateRequest("Hello, world", Lang.En, Lang.ZhHans);
            var latest = string.Empty;
            await foreach (var piece in TranslateServiceStore.Translate(service, request, cts.Token))
            {
                latest = piece;
            }

            return string.IsNullOrWhiteSpace(latest) ? (false, "服务没有返回内容") : (true, latest);
        }
        catch (TranslateError error)
        {
            return (false, error.Message);
        }
        catch (OperationCanceledException)
        {
            return (false, "超时（20 秒）");
        }
        catch (Exception ex)
        {
            return (false, ex.Message);
        }
    }

    /// <summary>停手一会儿再做（模型列表：改地址、Key 时每个字都会触发，最后一下过 0.6 s 才取）。</summary>
    private sealed class DispatcherQueueTimerHolder
    {
        private readonly Microsoft.UI.Dispatching.DispatcherQueueTimer _timer;

        public DispatcherQueueTimerHolder(Microsoft.UI.Dispatching.DispatcherQueue queue, TimeSpan delay, Action run)
        {
            _timer = queue.CreateTimer();
            _timer.Interval = delay;
            _timer.IsRepeating = false;
            _timer.Tick += (_, _) => run();
        }

        public void Restart()
        {
            _timer.Stop();
            _timer.Start();
        }

        public void Stop() => _timer.Stop();
    }
}
