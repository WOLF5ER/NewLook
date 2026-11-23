param([switch]$SmokeTest, [switch]$EnableUpdates, [Action]$UpdateReady, [byte[]]$BrandIcon)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Add-Type @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Threading;

public sealed class OutsidePanelClick : IDisposable
{
    private const int LowLevelMouseHook = 14;
    private const int LeftButtonDown = 0x0201;
    private const int RightButtonDown = 0x0204;
    private const int MiddleButtonDown = 0x0207;
    private const uint RootOwner = 3;

    [StructLayout(LayoutKind.Sequential)]
    private struct Point { public int X, Y; }

    private delegate IntPtr MouseCallback(int code, IntPtr message, IntPtr data);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SetWindowsHookEx(int type, MouseCallback callback, IntPtr module, uint thread);
    [DllImport("user32.dll")] private static extern bool UnhookWindowsHookEx(IntPtr hook);
    [DllImport("user32.dll")] private static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr message, IntPtr data);
    [DllImport("user32.dll")] private static extern IntPtr WindowFromPoint(Point point);
    [DllImport("user32.dll")] private static extern IntPtr GetAncestor(IntPtr window, uint flags);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
    [DllImport("user32.dll")] private static extern bool IsWindowEnabled(IntPtr window);
    [DllImport("kernel32.dll")] private static extern uint GetCurrentProcessId();
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr GetModuleHandle(string name);

    private readonly SynchronizationContext dispatcher;
    private readonly Action dismiss;
    private readonly MouseCallback callback;
    private readonly uint process = GetCurrentProcessId();
    private IntPtr hook;
    private IntPtr owner;
    private int version;

    public OutsidePanelClick(SynchronizationContext dispatcher, Action dismiss)
    {
        this.dispatcher = dispatcher;
        this.dismiss = dismiss;
        callback = OnMouse;
    }

    public void SetEnabled(bool enabled, IntPtr window)
    {
        if (enabled && hook == IntPtr.Zero)
        {
            owner = window;
            hook = SetWindowsHookEx(LowLevelMouseHook, callback, GetModuleHandle(null), 0);
            version++;
        }
        else if (!enabled)
            Dispose();
    }

    public bool IsListening { get { return hook != IntPtr.Zero; } }

    public void Dispose()
    {
        if (hook == IntPtr.Zero) return;
        UnhookWindowsHookEx(hook);
        hook = IntPtr.Zero;
        version++;
    }

    private bool BelongsToNewLook(IntPtr window)
    {
        uint windowProcess;
        if (window == IntPtr.Zero) return false;
        GetWindowThreadProcessId(window, out windowProcess);
        if (windowProcess == process) return true;
        var root = GetAncestor(window, RootOwner);
        if (root == IntPtr.Zero || root == window) return false;
        GetWindowThreadProcessId(root, out windowProcess);
        return windowProcess == process;
    }

    private IntPtr OnMouse(int code, IntPtr message, IntPtr data)
    {
        var kind = message.ToInt32();
        if (code == 0 && (kind == LeftButtonDown || kind == RightButtonDown || kind == MiddleButtonDown)
            && IsWindowEnabled(owner))
        {
            // The click coordinates are used only for this hit test, never stored or sent to WPF.
            var point = (Point)Marshal.PtrToStructure(data, typeof(Point));
            if (!BelongsToNewLook(WindowFromPoint(point)))
            {
                try { dispatcher.Post(Notify, version); }
                catch (InvalidOperationException) { } // Dispatcher is shutting down.
            }
        }
        return CallNextHookEx(IntPtr.Zero, code, message, data);
    }

    private void Notify(object notificationVersion)
    {
        if (IsListening && (int)notificationVersion == version)
            dismiss();
    }
}

public static class ShortcutShell
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct FileInfo
    {
        public IntPtr Icon;
        public int IconIndex;
        public uint Attributes;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string DisplayName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 80)] public string TypeName;
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr SHGetFileInfo(string path, uint attributes,
        out FileInfo info, uint size, uint flags);

    [DllImport("user32.dll")]
    public static extern bool DestroyIcon(IntPtr icon);

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern uint ExtractIconEx(string path, int index,
        out IntPtr largeIcon, IntPtr smallIcon, uint count);

    public static IntPtr GetResourceIcon(string path, int index)
    {
        IntPtr icon;
        ExtractIconEx(path, index, out icon, IntPtr.Zero, 1);
        return icon;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool MoveFileEx(string source, string destination, uint flags);

    public static bool TryRename(string source, string destination)
    {
        const uint writeThrough = 8;
        const int differentVolume = 17;
        if (MoveFileEx(source, destination, writeThrough))
            return true;
        int error = Marshal.GetLastWin32Error();
        if (error == differentVolume)
            return false;
        throw new System.ComponentModel.Win32Exception(error);
    }

    [ComImport, Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IShellItem
    {
        void BindToHandler(IntPtr context, ref Guid handler, ref Guid iid, out IntPtr result);
        void GetParent(out IShellItem parent);
        void GetDisplayName(uint nameType, [MarshalAs(UnmanagedType.LPWStr)] out string name);
        void GetAttributes(uint mask, out uint attributes);
        void Compare(IShellItem other, uint hints, out int order);
    }

    [ComVisible(true), Guid("04B0F1A7-9490-44BC-96E1-4296A31252E2")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IMoveProgress
    {
        void StartOperations();
        void FinishOperations(int result);
        void PreRenameItem(uint flags, IShellItem item, [MarshalAs(UnmanagedType.LPWStr)] string name);
        void PostRenameItem(uint flags, IShellItem item, [MarshalAs(UnmanagedType.LPWStr)] string name, int result, IShellItem created);
        void PreMoveItem(uint flags, IShellItem item, IShellItem folder, [MarshalAs(UnmanagedType.LPWStr)] string name);
        void PostMoveItem(uint flags, IShellItem item, IShellItem folder, [MarshalAs(UnmanagedType.LPWStr)] string name, int result, IShellItem created);
        void PreCopyItem(uint flags, IShellItem item, IShellItem folder, [MarshalAs(UnmanagedType.LPWStr)] string name);
        void PostCopyItem(uint flags, IShellItem item, IShellItem folder, [MarshalAs(UnmanagedType.LPWStr)] string name, int result, IShellItem created);
        void PreDeleteItem(uint flags, IShellItem item);
        void PostDeleteItem(uint flags, IShellItem item, int result, IShellItem created);
        void PreNewItem(uint flags, IShellItem folder, [MarshalAs(UnmanagedType.LPWStr)] string name);
        void PostNewItem(uint flags, IShellItem folder, [MarshalAs(UnmanagedType.LPWStr)] string name, [MarshalAs(UnmanagedType.LPWStr)] string template, uint attributes, int result, IShellItem created);
        void UpdateProgress(uint total, uint completed);
        void ResetTimer();
        void PauseTimer();
        void ResumeTimer();
    }

    [ComVisible(true), ClassInterface(ClassInterfaceType.None)]
    public sealed class MoveProgress : IMoveProgress
    {
        public string Destination;
        public string Error;
        public void StartOperations() { }
        public void FinishOperations(int result) { }
        public void PreRenameItem(uint flags, IShellItem item, string name) { }
        public void PostRenameItem(uint flags, IShellItem item, string name, int result, IShellItem created) { }
        public void PreMoveItem(uint flags, IShellItem item, IShellItem folder, string name) { }
        public void PostMoveItem(uint flags, IShellItem item, IShellItem folder, string name, int result, IShellItem created)
        {
            if (result < 0) Error = Marshal.GetExceptionForHR(result).Message;
            else if (created != null) created.GetDisplayName(0x80058000, out Destination);
        }
        public void PreCopyItem(uint flags, IShellItem item, IShellItem folder, string name) { }
        public void PostCopyItem(uint flags, IShellItem item, IShellItem folder, string name, int result, IShellItem created) { }
        public void PreDeleteItem(uint flags, IShellItem item) { }
        public void PostDeleteItem(uint flags, IShellItem item, int result, IShellItem created) { }
        public void PreNewItem(uint flags, IShellItem folder, string name) { }
        public void PostNewItem(uint flags, IShellItem folder, string name, string template, uint attributes, int result, IShellItem created) { }
        public void UpdateProgress(uint total, uint completed) { }
        public void ResetTimer() { }
        public void PauseTimer() { }
        public void ResumeTimer() { }
    }

    [ComImport, Guid("947AAB5F-0A5C-4C13-B4D6-4BF7836FC9F8")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IFileOperation
    {
        void Advise(IntPtr sink, out uint cookie);
        void Unadvise(uint cookie);
        void SetOperationFlags(uint flags);
        void SetProgressMessage(IntPtr message);
        void SetProgressDialog(IntPtr dialog);
        void SetProperties(IntPtr properties);
        void SetOwnerWindow(IntPtr owner);
        void ApplyPropertiesToItem(IShellItem item);
        void ApplyPropertiesToItems(IntPtr items);
        void RenameItem(IShellItem item, IntPtr name, IntPtr sink);
        void RenameItems(IntPtr items, IntPtr name);
        void MoveItem(IShellItem item, IShellItem destination,
            [MarshalAs(UnmanagedType.LPWStr)] string name, IMoveProgress sink);
        void MoveItems(IntPtr items, IShellItem destination);
        void CopyItem(IShellItem item, IShellItem destination, IntPtr name, IntPtr sink);
        void CopyItems(IntPtr items, IShellItem destination);
        void DeleteItem(IShellItem item, IntPtr sink);
        void DeleteItems(IntPtr items);
        void NewItem(IShellItem directory, uint attributes, IntPtr name, IntPtr template, IntPtr sink);
        void PerformOperations();
        void GetAnyOperationsAborted([MarshalAs(UnmanagedType.Bool)] out bool aborted);
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
    private static extern void SHCreateItemFromParsingName(string path, IntPtr context,
        ref Guid interfaceId, out IShellItem item);

    public static void MoveSharedFiles(Dictionary<string, MoveProgress> files, string destination, IntPtr owner)
    {
        var clsid = new Guid("3AD05575-8857-4850-9277-11B85BDB8E09");
        var shellItemId = typeof(IShellItem).GUID;
        var operation = (IFileOperation)Activator.CreateInstance(Type.GetTypeFromCLSID(clsid, true));
        IShellItem folder = null;
        try
        {
            const uint renameOnCollision = 0x0008;
            const uint noErrorUi = 0x0400;
            const uint noConnectedItems = 0x2000;
            const uint showElevationPrompt = 0x00040000;
            operation.SetOperationFlags(renameOnCollision | noErrorUi | noConnectedItems | showElevationPrompt);
            operation.SetOwnerWindow(owner);
            SHCreateItemFromParsingName(destination, IntPtr.Zero, ref shellItemId, out folder);
            foreach (var fileOperation in files)
            {
                IShellItem file = null;
                try
                {
                    SHCreateItemFromParsingName(fileOperation.Key, IntPtr.Zero, ref shellItemId, out file);
                    operation.MoveItem(file, folder, null, fileOperation.Value);
                }
                catch (COMException error) { fileOperation.Value.Error = error.Message; }
                finally { if (file != null) Marshal.ReleaseComObject(file); }
            }
            operation.PerformOperations();
        }
        finally
        {
            if (folder != null) Marshal.ReleaseComObject(folder);
            Marshal.ReleaseComObject(operation);
        }
    }

    public static IntPtr GetIcon(string path, bool useFileType)
    {
        const uint icon = 0x100;
        const uint useFileAttributes = 0x10;
        FileInfo info;
        SHGetFileInfo(path, 0x80, out info, (uint)Marshal.SizeOf(typeof(FileInfo)),
            icon | (useFileType ? useFileAttributes : 0));
        return info.Icon;
    }
}
'@

$statePath = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'NewLook\state.json'
$desktopPath = [Environment]::GetFolderPath('DesktopDirectory')
$publicDesktopPath = [Environment]::GetFolderPath('CommonDesktopDirectory')
if ($SmokeTest) {
    $testRoot = Join-Path ([IO.Path]::GetTempPath()) ('NewLook-' + [guid]::NewGuid())
    $statePath = Join-Path $testRoot 'state.json'
    $desktopPath = Join-Path $testRoot 'Desktop'
    $publicDesktopPath = Join-Path $testRoot 'PublicDesktop'
}
$storagePath = Join-Path (Split-Path -Parent $statePath) 'Shortcuts'
$publicStoragePath = Join-Path $storagePath 'Public'
$moveError = ''

function Read-State {
    if (Test-Path -LiteralPath $statePath) {
        $saved = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
    } else {
        $saved = [pscustomobject]@{ shortcuts = @(); pinned = $false; note = '' }
    }
    foreach ($property in 'folders', 'shortcutOrder') {
        if (!$saved.PSObject.Properties[$property]) {
            $saved | Add-Member -NotePropertyName $property -NotePropertyValue @()
        }
    }
    $saved
}

function Save-State {
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $statePath))
    $tempPath = "$statePath.tmp"
    [IO.File]::WriteAllText($tempPath, ($script:state | ConvertTo-Json -Depth 4))
    if ([IO.File]::Exists($statePath)) {
        $backupPath = "$statePath.bak"
        [IO.File]::Replace($tempPath, $statePath, $backupPath)
        [IO.File]::Delete($backupPath)
    } else {
        [IO.File]::Move($tempPath, $statePath)
    }
}

$script:state = Read-State

function New-Overlay($content) {
    $xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
 xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
 Title="Shelfside" WindowStyle="None" ResizeMode="NoResize" AllowsTransparency="True"
 Background="Transparent" Foreground="#172C2A" Topmost="True" xml:lang="ru-RU"
 ShowInTaskbar="False" SizeToContent="WidthAndHeight" FontFamily="Segoe UI"
 FontSize="14" UseLayoutRounding="True">
 <Window.Resources>
  <SolidColorBrush x:Key="Ink" Color="#172C2A"/>
  <SolidColorBrush x:Key="Muted" Color="#536863"/>
  <SolidColorBrush x:Key="Accent" Color="#166358"/>
  <SolidColorBrush x:Key="Hover" Color="#E1EFE9"/>
  <SolidColorBrush x:Key="Stroke" Color="#D9E5DF"/>
  <Style TargetType="Button">
   <Setter Property="Foreground" Value="{StaticResource Ink}"/>
   <Setter Property="Background" Value="Transparent"/>
   <Setter Property="MinHeight" Value="36"/>
   <Setter Property="Padding" Value="10,6"/>
   <Setter Property="Cursor" Value="Hand"/>
   <Setter Property="HorizontalContentAlignment" Value="Center"/>
   <Setter Property="Template">
    <Setter.Value>
     <ControlTemplate TargetType="Button">
      <Border x:Name="Surface" Background="{TemplateBinding Background}" CornerRadius="10"
       BorderThickness="1" BorderBrush="Transparent" Padding="{TemplateBinding Padding}">
       <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="Center"/>
      </Border>
      <ControlTemplate.Triggers>
       <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Surface" Property="Background" Value="{StaticResource Hover}"/></Trigger>
       <Trigger Property="IsPressed" Value="True"><Setter TargetName="Surface" Property="Background" Value="#CEE4DB"/></Trigger>
       <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Surface" Property="BorderBrush" Value="{StaticResource Accent}"/></Trigger>
      </ControlTemplate.Triggers>
     </ControlTemplate>
    </Setter.Value>
   </Setter>
  </Style>
  <Style x:Key="ShortcutIcon" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
   <Setter Property="Padding" Value="6,6"/>
   <Setter Property="Margin" Value="2"/>
  </Style>
  <Style x:Key="RailButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
   <Setter Property="FontFamily" Value="Segoe MDL2 Assets"/>
   <Setter Property="FontSize" Value="16"/>
   <Setter Property="Width" Value="36"/>
   <Setter Property="Height" Value="40"/>
   <Setter Property="Padding" Value="0"/>
  </Style>
 </Window.Resources>
 $content
</Window>
"@
    [Windows.Markup.XamlReader]::Parse($xaml)
}

$left = New-Overlay @'
<DockPanel LastChildFill="False" Height="402">
 <Border DockPanel.Dock="Left" Background="#F4F6FAF7" BorderBrush="{StaticResource Stroke}" BorderThickness="0,1,1,1"
  CornerRadius="0,18,18,0" VerticalAlignment="Center" Padding="4,7,6,7">
  <StackPanel>
   <Button x:Name="Handle" Style="{StaticResource RailButton}" Content="&#xE8B7;" ToolTip="Открыть ярлыки" AutomationProperties.Name="Открыть ярлыки"/>
   <Border Height="1" Background="{StaticResource Stroke}" Margin="6,3"/>
   <Button x:Name="Widgets" Style="{StaticResource RailButton}" Content="&#xECA5;" ToolTip="Показать виджеты" AutomationProperties.Name="Показать виджеты"/>
  </StackPanel>
 </Border>
 <Border x:Name="Folder" DockPanel.Dock="Left" Visibility="Collapsed" Opacity="0"
  Background="#FCF8FCF9" CornerRadius="25" BorderBrush="{StaticResource Stroke}" BorderThickness="1"
  Width="556" Margin="12,0,0,0" AllowDrop="True">
  <Grid>
   <Grid.ColumnDefinitions><ColumnDefinition Width="174"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
   <Border CornerRadius="24,0,0,24" Background="#EAF3EE" Padding="15,20,12,14">
    <DockPanel LastChildFill="True">
     <StackPanel DockPanel.Dock="Top" Margin="0,0,0,11">
      <TextBlock Text="Shelfside" FontSize="20" FontWeight="Bold" Margin="8,0,0,15"/>
      <TextBlock Text="Папки" Foreground="{StaticResource Muted}" FontSize="12" FontWeight="SemiBold" Margin="8,0,0,0"/>
     </StackPanel>
     <StackPanel DockPanel.Dock="Bottom">
      <Button x:Name="Update" Content="Обновить" Visibility="Collapsed" Background="#D6EBE1" Foreground="{StaticResource Accent}" FontWeight="SemiBold" Margin="0,0,0,5"/>
      <Button x:Name="NewFolder" Content="+  Новая папка" HorizontalContentAlignment="Left" Foreground="{StaticResource Accent}" FontWeight="SemiBold"/>
      <StackPanel x:Name="FolderEditor" Visibility="Collapsed" Margin="2,5,2,0">
       <TextBlock Text="Название папки" FontSize="12" Margin="2,0,0,4"/>
       <TextBox x:Name="FolderName" MaxLength="40" Padding="5" AutomationProperties.Name="Название папки"/>
       <Button x:Name="CreateFolder" Content="Создать" HorizontalContentAlignment="Left" Margin="0,3,0,0"/>
      </StackPanel>
     </StackPanel>
     <ScrollViewer HorizontalScrollBarVisibility="Disabled" VerticalScrollBarVisibility="Auto">
      <StackPanel x:Name="FolderTabs"/>
     </ScrollViewer>
    </DockPanel>
   </Border>
   <Grid Grid.Column="1" Margin="22,17,16,14">
    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
    <DockPanel Grid.Row="0" Margin="0,0,0,13">
     <Button x:Name="Pin" DockPanel.Dock="Right" Content="Закрепить" Background="#EAF3EE" Foreground="{StaticResource Accent}" FontSize="12" FontWeight="SemiBold" MinWidth="86" VerticalAlignment="Center" Margin="5,0,0,0"/>
     <Button x:Name="AddDesktop" DockPanel.Dock="Right" Content="+ Добавить" Background="#D6EBE1" Foreground="{StaticResource Accent}" FontSize="12" FontWeight="SemiBold" VerticalAlignment="Center" Margin="5,0,0,0" ToolTip="Выбрать ярлыки на рабочем столе"/>
     <TextBlock x:Name="FolderTitle" FontSize="25" FontWeight="SemiBold" TextTrimming="CharacterEllipsis" VerticalAlignment="Center"/>
    </DockPanel>
    <Border Grid.Row="1" Background="#FFFFFF" CornerRadius="16" BorderThickness="1" BorderBrush="{StaticResource Stroke}" Padding="5">
     <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
      <WrapPanel x:Name="Shortcuts" ItemWidth="82" ItemHeight="84" MinHeight="255" Background="Transparent"/>
     </ScrollViewer>
    </Border>
    <TextBlock x:Name="Hint" Grid.Row="2" Foreground="{StaticResource Muted}" FontSize="12" Margin="1,10,0,0" TextWrapping="Wrap" AutomationProperties.LiveSetting="Polite"/>
   </Grid>
  </Grid>
 </Border>
</DockPanel>
'@

$right = New-Overlay @'
<Border x:Name="WidgetPanel" Opacity="0" Background="#FCF8FCF9" CornerRadius="25" BorderBrush="{StaticResource Stroke}"
 BorderThickness="1" Width="312" Padding="18" Margin="0,0,18,0">
 <StackPanel>
  <DockPanel Margin="0,0,0,14">
   <Button x:Name="CloseWidgets" Style="{StaticResource RailButton}" DockPanel.Dock="Right" Content="&#xE8BB;" ToolTip="Закрыть виджеты" AutomationProperties.Name="Закрыть виджеты"/>
   <TextBlock Text="Виджеты" FontSize="25" FontWeight="SemiBold" VerticalAlignment="Center"/>
  </DockPanel>
  <Border Background="#EAF3EE" CornerRadius="16" Padding="14,11" Margin="0,0,0,8">
   <StackPanel>
    <TextBlock Text="Сегодня" Foreground="{StaticResource Accent}" FontSize="12" FontWeight="SemiBold"/>
    <TextBlock x:Name="Today" FontSize="19" FontWeight="SemiBold" Margin="0,1,0,0"/>
   </StackPanel>
  </Border>
  <Border Background="#FFFFFF" BorderBrush="{StaticResource Stroke}" BorderThickness="1" CornerRadius="16" Padding="7">
   <Calendar x:Name="Calendar" Foreground="{StaticResource Ink}" HorizontalAlignment="Center">
    <Calendar.CalendarDayButtonStyle>
     <Style TargetType="CalendarDayButton">
      <Setter Property="Foreground" Value="{StaticResource Ink}"/>
      <Setter Property="MinWidth" Value="32"/>
      <Setter Property="MinHeight" Value="23"/>
      <Setter Property="Template">
       <Setter.Value>
        <ControlTemplate TargetType="CalendarDayButton">
         <Border x:Name="Day" CornerRadius="6" Margin="2,1" Background="Transparent" BorderThickness="1" BorderBrush="Transparent">
          <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
         </Border>
         <ControlTemplate.Triggers>
          <Trigger Property="IsInactive" Value="True"><Setter Property="Foreground" Value="#677A75"/></Trigger>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Day" Property="Background" Value="{StaticResource Hover}"/></Trigger>
          <Trigger Property="IsToday" Value="True"><Setter TargetName="Day" Property="Background" Value="#D6EBE1"/><Setter Property="FontWeight" Value="Bold"/></Trigger>
          <Trigger Property="IsSelected" Value="True"><Setter TargetName="Day" Property="Background" Value="{StaticResource Accent}"/><Setter Property="Foreground" Value="White"/></Trigger>
          <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Day" Property="BorderBrush" Value="{StaticResource Accent}"/></Trigger>
         </ControlTemplate.Triggers>
        </ControlTemplate>
       </Setter.Value>
      </Setter>
     </Style>
    </Calendar.CalendarDayButtonStyle>
    <Calendar.CalendarItemStyle>
     <Style TargetType="CalendarItem">
      <Setter Property="Template">
       <Setter.Value>
        <ControlTemplate TargetType="CalendarItem">
         <ControlTemplate.Resources>
          <DataTemplate x:Key="{x:Static CalendarItem.DayTitleTemplateResourceKey}">
           <TextBlock Text="{Binding}" Foreground="{StaticResource Muted}" FontSize="11" FontWeight="SemiBold" HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </DataTemplate>
         </ControlTemplate.Resources>
         <Grid x:Name="PART_Root" Width="236">
          <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
          <DockPanel Margin="0,0,0,3">
           <Button x:Name="PART_PreviousButton" DockPanel.Dock="Left" Content="&#x2039;" FontSize="18" Padding="8,0" MinHeight="30" AutomationProperties.Name="Предыдущий месяц"/>
           <Button x:Name="PART_NextButton" DockPanel.Dock="Right" Content="&#x203A;" FontSize="18" Padding="8,0" MinHeight="30" AutomationProperties.Name="Следующий месяц"/>
           <Button x:Name="PART_HeaderButton" FontWeight="SemiBold" FontSize="13" MinHeight="30"/>
          </DockPanel>
          <Grid x:Name="PART_MonthView" Grid.Row="1">
           <Grid.ColumnDefinitions>
            <ColumnDefinition/><ColumnDefinition/><ColumnDefinition/><ColumnDefinition/><ColumnDefinition/><ColumnDefinition/><ColumnDefinition/>
           </Grid.ColumnDefinitions>
           <Grid.RowDefinitions>
            <RowDefinition Height="24"/><RowDefinition Height="23"/><RowDefinition Height="23"/><RowDefinition Height="23"/><RowDefinition Height="23"/><RowDefinition Height="23"/><RowDefinition Height="23"/>
           </Grid.RowDefinitions>
          </Grid>
          <Grid x:Name="PART_YearView" Grid.Row="1" Visibility="Collapsed" Height="162">
           <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition/><ColumnDefinition/><ColumnDefinition/></Grid.ColumnDefinitions>
           <Grid.RowDefinitions><RowDefinition/><RowDefinition/><RowDefinition/></Grid.RowDefinitions>
          </Grid>
          <Rectangle x:Name="PART_DisabledVisual" Grid.RowSpan="2" Fill="#70FFFFFF" Visibility="Collapsed" IsHitTestVisible="False"/>
         </Grid>
        </ControlTemplate>
       </Setter.Value>
      </Setter>
     </Style>
    </Calendar.CalendarItemStyle>
   </Calendar>
  </Border>
  <TextBlock Text="Заметка" FontSize="14" FontWeight="SemiBold" Margin="2,14,0,6"/>
  <Border Background="#FFFFFF" BorderBrush="{StaticResource Stroke}" BorderThickness="1" CornerRadius="14" Padding="4">
   <TextBox x:Name="Note" Height="90" AcceptsReturn="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" Padding="7"
    Background="Transparent" Foreground="{StaticResource Ink}" CaretBrush="{StaticResource Accent}" BorderThickness="0" AutomationProperties.Name="Заметка"/>
  </Border>
 </StackPanel>
</Border>
'@
if ($BrandIcon) {
    $iconStream = [IO.MemoryStream]::new($BrandIcon, $false)
    try {
        $iconDecoder = [Windows.Media.Imaging.IconBitmapDecoder]::new(
            $iconStream, [Windows.Media.Imaging.BitmapCreateOptions]::None,
            [Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
        $windowIcon = $iconDecoder.Frames | Sort-Object PixelWidth -Descending | Select-Object -First 1
        $left.Icon = $windowIcon
        $right.Icon = $windowIcon
    } finally { $iconStream.Dispose() }
}

$folder = $left.FindName('Folder')
$folderTitle = $left.FindName('FolderTitle')
$pin = $left.FindName('Pin')
$hint = $left.FindName('Hint')
$shortcuts = $left.FindName('Shortcuts')
$tabs = $left.FindName('FolderTabs')
$editor = $left.FindName('FolderEditor')
$folderName = $left.FindName('FolderName')
$script:activeFolder = ''
$script:dragStart = $null
$script:draggingShortcut = $false
$script:hoverFolder = $null
$dragFormat = 'NewLook.ShortcutPath'
$note = $right.FindName('Note')
$note.Text = $script:state.note
$right.FindName('Today').Text = [DateTime]::Today.ToString('d MMMM, dddd', [Globalization.CultureInfo]::GetCultureInfo('ru-RU'))
$widgetPanel = $right.FindName('WidgetPanel')
$folderTransition = @{ Panel = $folder; Offset = -18; Open = $false; Version = 0 }
$widgetTransition = @{ Panel = $widgetPanel; Window = $right; Offset = 18; Open = $false; Version = 0 }
foreach ($transition in $folderTransition, $widgetTransition) {
    $transition.Panel.RenderTransform = [Windows.Media.TranslateTransform]::new($transition.Offset, 0)
}

function Get-DesktopOrigin([string]$path) {
    $extension = [IO.Path]::GetExtension($path)
    if ($extension -notin '.lnk', '.url', '.exe') { return }
    $parent = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($path))
    if ($desktopPath -and $parent.TrimEnd('\') -eq $desktopPath.TrimEnd('\')) { return 'Personal' }
    if ($extension -ne '.exe' -and $publicDesktopPath -and
        $parent.TrimEnd('\') -eq $publicDesktopPath.TrimEnd('\')) { return 'Public' }
}

function Test-DesktopShortcut([string]$path) {
    [bool](Get-DesktopOrigin $path)
}

function Move-Shortcut([string]$source, [string]$destinationFolder) {
    $script:moveError = ''
    try {
        if (!(Test-Path -LiteralPath $source -PathType Leaf)) { throw 'Исходный ярлык не найден.' }
        if (!(Test-Path -LiteralPath $destinationFolder -PathType Container)) {
            if ($destinationFolder -notin $storagePath, $publicStoragePath) { throw 'Папка рабочего стола недоступна.' }
            [void][IO.Directory]::CreateDirectory($destinationFolder)
        }
        $destination = Join-Path $destinationFolder ([IO.Path]::GetFileName($source))
        if (Test-Path -LiteralPath $destination) { throw 'Ярлык с таким именем уже есть в месте назначения.' }
        if (![ShortcutShell]::TryRename($source, $destination)) {
            # Publish a complete copy before removing the original on a different volume.
            $stage = Join-Path $destinationFolder ('.NewLook-' + [guid]::NewGuid() + '.tmp')
            $inputFile = [IO.File]::Open($source, 'Open', 'Read', 'Read')
            try {
                [IO.File]::Copy($source, $stage, $false)
                $outputFile = [IO.File]::Open($stage, 'Open', 'Write', 'None')
                try {
                    $outputFile.Flush($true)
                } finally { $outputFile.Dispose() }
                if (![ShortcutShell]::TryRename($stage, $destination)) { throw 'Не удалось сохранить ярлык.' }
            } finally {
                $inputFile.Dispose()
                [IO.File]::Delete($stage)
            }
            try { [IO.File]::Delete($source) }
            catch { throw 'Оба файла сохранены, так как исходный ярлык не удалось удалить.' }
        }
        $true
    } catch {
        $script:moveError = $_.Exception.GetBaseException().Message
        $false
    }
}

function Request-SharedMoves([string[]]$names, [bool]$restore) {
    if (!$SmokeTest) {
        $effect = if ($restore) { 'снова появятся на рабочем столе у всех пользователей' }
            else { 'исчезнут с рабочего стола у всех пользователей' }
        $question = "Общие ярлыки $effect. Windows может запросить разрешение администратора.`n`nПродолжить?"
        if ([Windows.MessageBox]::Show($left, $question, 'Общий рабочий стол', 'YesNo', 'Warning', 'No') -ne 'Yes') {
            foreach ($name in $names) {
                [pscustomobject]@{ Name = $name; Success = $false; Error = 'Перенос общих ярлыков отменён.' }
            }
            return
        }
    }
    $from, $to = if ($restore) { $publicStoragePath, $publicDesktopPath }
        else { $publicDesktopPath, $publicStoragePath }
    $pending = [Collections.Generic.List[string]]::new()
    foreach ($name in $names) {
        $source = Join-Path $from $name
        $destination = Join-Path $to $name
        if (!(Test-Path -LiteralPath $source -PathType Leaf)) {
            [pscustomobject]@{ Name = $name; Success = $false; Error = 'Исходный ярлык не найден.' }
        } elseif (Test-Path -LiteralPath $destination) {
            [pscustomobject]@{ Name = $name; Success = $false; Error = 'Ярлык с таким именем уже есть в месте назначения.' }
        } else { $pending.Add($source) }
    }
    if (!$pending.Count) { return }
    $failure = 'Windows не завершила перенос. Проверьте разрешение или наличие ярлыка в папке назначения.'
    $operations = [Collections.Generic.Dictionary[string, ShortcutShell+MoveProgress]]::new()
    foreach ($source in $pending) { $operations.Add($source, [ShortcutShell+MoveProgress]::new()) }
    try {
        if (!$restore) { [void][IO.Directory]::CreateDirectory($publicStoragePath) }
        $owner = [Windows.Interop.WindowInteropHelper]::new($left).Handle
        [ShortcutShell]::MoveSharedFiles($operations, $to, $owner)
    } catch {
        $failure = $_.Exception.GetBaseException().Message
    }
    foreach ($source in $pending) {
        $name = [IO.Path]::GetFileName($source)
        $result = $operations[$source]
        $moved = $result.Destination -and !(Test-Path -LiteralPath $source) -and
            (Test-Path -LiteralPath $result.Destination -PathType Leaf)
        $reason = if ($result.Error) { $result.Error } else { $failure }
        [pscustomobject]@{ Name = $name; Success = $moved; Destination = $result.Destination;
            Error = $(if (!$moved) { $reason } else { '' }) }
    }
}

function Register-HiddenShortcut([string]$path, [string]$destination) {
    foreach ($group in $script:state.folders) {
        $group.items = @($group.items | ForEach-Object { if ($_ -eq $path) { $destination } else { $_ } })
    }
    $script:state.shortcutOrder = @($script:state.shortcutOrder | ForEach-Object {
        if ($_ -eq $path) { $destination } else { $_ }
    })
    $script:state.shortcuts = @($script:state.shortcuts | Where-Object { $_ -ne $path })
}

function Add-Shortcuts([string[]]$paths, [string]$targetFolder = $script:activeFolder) {
    $script:moveError = ''
    $moved = 0
    $linked = 0
    $ignored = 0
    $errors = [Collections.Generic.List[string]]::new()
    $shared = [Collections.Generic.List[string]]::new()
    $added = [Collections.Generic.List[string]]::new()
    $executables = @($paths | Where-Object {
        [IO.Path]::GetExtension($_) -eq '.exe' -and (Get-DesktopOrigin $_) -eq 'Personal'
    })
    $moveExecutables = $true
    if (!$SmokeTest -and $executables.Count) {
        $warning = "Выбрано файлов приложений: $($executables.Count). Shelfside переместит сами файлы. Приложение, которому нужны соседние файлы, может перестать запускаться.`n`nПродолжить?"
        $moveExecutables = [Windows.MessageBox]::Show($left, $warning,
            'Файлы приложений', 'YesNo', 'Warning', 'No') -eq 'Yes'
    }
    foreach ($path in ($paths | Select-Object -Unique)) {
        $origin = Get-DesktopOrigin $path
        if ($origin -eq 'Public') {
            $shared.Add([IO.Path]::GetFileName($path))
            continue
        }
        if ($origin -eq 'Personal') {
            if (!$moveExecutables -and $path -in $executables) {
                $errors.Add(("{0}: перенос файла приложения отменён." -f [IO.Path]::GetFileName($path)))
                continue
            }
            if (Move-Shortcut $path $storagePath) {
                $destination = Join-Path $storagePath ([IO.Path]::GetFileName($path))
                Register-HiddenShortcut $path $destination
                $added.Add($destination)
                $moved++
            } else { $errors.Add(("{0}: {1}" -f [IO.Path]::GetFileName($path), $script:moveError)) }
            continue
        }
        if ([IO.Path]::GetExtension($path) -in '.lnk', '.url', '.appref-ms' -and
            (Test-Path -LiteralPath $path -PathType Leaf) -and
            $path -notin $script:state.shortcuts) {
            $script:state.shortcuts = @($script:state.shortcuts) + $path
            $added.Add($path)
            $linked++
        } else {
            $ignored++
        }
    }
    if ($shared.Count) {
        foreach ($result in @(Request-SharedMoves $shared.ToArray() $false)) {
            if ($result.Success) {
                $source = Join-Path $publicDesktopPath $result.Name
                $destination = $result.Destination
                Register-HiddenShortcut $source $destination
                $added.Add($destination)
                $moved++
            } else { $errors.Add(("{0}: {1}" -f $result.Name, $result.Error)) }
        }
    }
    if ($targetFolder -and $added.Count) {
        foreach ($group in $script:state.folders) {
            $group.items = @($group.items | Where-Object { $_ -notin $added })
            if ($group.Id -eq $targetFolder) { $group.items += $added.ToArray() }
        }
    }
    try { Save-State } catch { $errors.Add($_.Exception.GetBaseException().Message) }
    $script:moveError = "Перемещено: $moved. Добавлено ссылок: $linked."
    if ($errors.Count) { $script:moveError += " Не удалось: $($errors.Count). " + ($errors | Select-Object -First 1) }
    if ($ignored) { $script:moveError += " Пропущено: $ignored." }
    Show-Shortcuts
}

function Get-ShortcutIcon($path) {
    $exists = Test-Path -LiteralPath $path -PathType Leaf
    $icon = [IntPtr]::Zero
    if ($exists -and [IO.Path]::GetExtension($path) -eq '.lnk') {
        try {
            if (!$script:shortcutReader) { $script:shortcutReader = New-Object -ComObject WScript.Shell }
            $link = $script:shortcutReader.CreateShortcut($path)
            if ($link.IconLocation -match '^\s*(.+),\s*(-?\d+)\s*$') {
                $resource = [Environment]::ExpandEnvironmentVariables($Matches[1].Trim('"'))
                $icon = [ShortcutShell]::GetResourceIcon($resource, [int]$Matches[2])
            }
            if ($icon -eq [IntPtr]::Zero -and $link.TargetPath) {
                $icon = [ShortcutShell]::GetIcon($link.TargetPath, $false)
            }
        } catch {
            # A broken or non-file target can still have a generic Shell icon.
        } finally {
            if ($link) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($link) }
        }
    }
    if ($icon -eq [IntPtr]::Zero) { $icon = [ShortcutShell]::GetIcon($path, !$exists) }
    if ($icon -eq [IntPtr]::Zero) { $icon = [ShortcutShell]::GetIcon('.lnk', $true) }
    if ($icon -eq [IntPtr]::Zero) { return }
    try {
        $source = [Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon(
            $icon, [Windows.Int32Rect]::Empty, [Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
        $source.Freeze()
        $source
    } finally {
        [void][ShortcutShell]::DestroyIcon($icon)
    }
}

function Save-Organization {
    try { Save-State } catch { $script:moveError = $_.Exception.GetBaseException().Message }
}

function Set-ShortcutOrder($order, [string]$path, [string]$before) {
    foreach ($item in $order) {
        if ($item -eq $path) { continue }
        if ($item -eq $before) { $path }
        $item
    }
    if (!$before -or $before -notin $order) { $path }
}

function Set-ShortcutPlacement([string]$path, [string]$folderId, [string]$before, [bool]$assign) {
    if (!$path -or $path -eq $before) { return }
    $target = $script:state.folders | Where-Object Id -eq $folderId
    if ($assign) {
        foreach ($group in $script:state.folders) {
            if ($group.Id -ne $folderId) { $group.items = @($group.items | Where-Object { $_ -ne $path }) }
        }
    }
    if ($target) {
        $target.items = @(Set-ShortcutOrder $target.items $path $before)
    } elseif (!$assign) {
        $script:state.shortcutOrder = @(Set-ShortcutOrder $script:visiblePaths $path $before)
    }
    Save-Organization
    Show-Shortcuts
}

function Select-ShortcutFolder([string]$id) {
    $script:activeFolder = $id
    foreach ($tab in $tabs.Children) {
        $active = $tab.Tag.Id -eq $id
        $tab.Background = if ($active) { '#D6EBE1' } else { 'Transparent' }
        $tab.FontWeight = if ($active) { 'SemiBold' } else { 'Normal' }
        [Windows.Automation.AutomationProperties]::SetItemStatus($tab, $(if ($active) { 'Открыта' } else { '' }))
    }
    Show-Shortcuts
}

function Show-FolderTabs {
    $tabs.Children.Clear()
    $all = [pscustomobject]@{ Id = ''; Name = 'Все ярлыки' }
    foreach ($group in (@($all) + @($script:state.folders))) {
        $tab = New-Object Windows.Controls.Button
        $tab.HorizontalContentAlignment = 'Left'
        $tab.ToolTip = $group.Name
        $content = New-Object Windows.Controls.StackPanel
        $content.Orientation = 'Horizontal'
        $glyph = New-Object Windows.Controls.TextBlock
        $glyph.FontFamily = 'Segoe MDL2 Assets'
        $glyph.Text = [string][char]$(if ($group.Id) { 0xE8B7 } else { 0xECA5 })
        $glyph.FontSize = 14
        $glyph.Margin = '0,2,9,0'
        $glyph.Foreground = $left.Resources['Accent']
        [void]$content.Children.Add($glyph)
        $name = New-Object Windows.Controls.TextBlock
        $name.Text = $group.Name
        $name.MaxWidth = 99
        $name.TextTrimming = 'CharacterEllipsis'
        [void]$content.Children.Add($name)
        $tab.Content = $content
        $tab.Tag = $group
        $tab.Margin = '0,0,0,4'
        [Windows.Automation.AutomationProperties]::SetName($tab, $group.Name)
        $tab.Add_Click({ param($sender, $eventArgs) Select-ShortcutFolder $sender.Tag.Id })
        [void]$tabs.Children.Add($tab)
    }
    Select-ShortcutFolder $script:activeFolder
}

function Add-ShortcutFolder([string]$name) {
    $name = $name.Trim()
    if (!$name -or $name -in 'Все ярлыки', 'All shortcuts' -or $name -in $script:state.folders.Name) { return $false }
    $group = [pscustomobject]@{ Id = [guid]::NewGuid().ToString(); Name = $name; items = @() }
    $script:state.folders = @($script:state.folders) + $group
    $script:activeFolder = $group.Id
    Save-Organization
    Show-FolderTabs
    $true
}

function Remove-ShortcutPlacement([string]$path) {
    foreach ($group in $script:state.folders) {
        $group.items = @($group.items | Where-Object { $_ -ne $path })
    }
    $script:state.shortcutOrder = @($script:state.shortcutOrder | Where-Object { $_ -ne $path })
}

function Show-Shortcuts {
    $shortcuts.Children.Clear()
    $stored = @(Get-ChildItem -LiteralPath $storagePath, $publicStoragePath -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in '.lnk', '.url', '.exe' } | ForEach-Object FullName)
    $references = @($script:state.shortcuts | Where-Object {
        $origin = Get-DesktopOrigin $_
        $store = if ($origin -eq 'Public') { $publicStoragePath } else { $storagePath }
        $_ -notin $stored -and (!$origin -or (Test-Path -LiteralPath $_) -or
            (Join-Path $store ([IO.Path]::GetFileName($_))) -notin $stored)
    })
    $all = @($stored + $references | Select-Object -Unique)
    $current = $script:state.folders | Where-Object Id -eq $script:activeFolder
    if ($current) {
        $folderTitle.Text = $current.Name
        $script:visiblePaths = @($current.items | Where-Object { $_ -in $all })
    } else {
        $folderTitle.Text = 'Все ярлыки'
        $order = @($script:state.shortcutOrder | Where-Object { $_ -in $all })
        $script:visiblePaths = @($order + @($all | Where-Object { $_ -notin $order }))
    }
    foreach ($path in $script:visiblePaths) {
        $menu = New-Object Windows.Controls.ContextMenu
        $remove = New-Object Windows.Controls.MenuItem
        $remove.Tag = $path
        if ($path -in $stored) {
            $isPublic = [IO.Path]::GetDirectoryName($path) -eq $publicStoragePath
            $remove.Header = if ($isPublic) { 'Вернуть на общий рабочий стол' } else { 'Вернуть на рабочий стол' }
            $remove.Add_Click({
                param($sender, $eventArgs)
                if ([IO.Path]::GetDirectoryName($sender.Tag) -eq $publicStoragePath) {
                    $result = Request-SharedMoves @([IO.Path]::GetFileName($sender.Tag)) $true
                    $returned = $result.Success
                    $script:moveError = $result.Error
                } else {
                    $returned = Move-Shortcut $sender.Tag $desktopPath
                }
                if ($returned) {
                    Remove-ShortcutPlacement $sender.Tag
                    Save-Organization
                }
                Show-Shortcuts
            })
            [void]$menu.Items.Add($remove)
        } else {
            if (Test-DesktopShortcut $path) {
                $hide = New-Object Windows.Controls.MenuItem
                $hide.Header = 'Переместить в Shelfside'
                $hide.Tag = $path
                $hide.Add_Click({
                    param($sender, $eventArgs)
                    Add-Shortcuts @($sender.Tag)
                })
                [void]$menu.Items.Add($hide)
            }
            $remove.Header = 'Убрать из Shelfside'
            $remove.Add_Click({
                param($sender, $eventArgs)
                $script:moveError = ''
                $script:state.shortcuts = @($script:state.shortcuts | Where-Object { $_ -ne $sender.Tag })
                Remove-ShortcutPlacement $sender.Tag
                Save-Organization
                Show-Shortcuts
            })
            [void]$menu.Items.Add($remove)
        }

        if ($script:state.folders.Count) {
            $moveMenu = New-Object Windows.Controls.MenuItem
            $moveMenu.Header = 'Переместить в папку'
            $rootGroup = [pscustomobject]@{ Id = ''; Name = 'Вне папок' }
            foreach ($group in (@($rootGroup) + @($script:state.folders))) {
                $destination = New-Object Windows.Controls.MenuItem
                $destination.Header = $group.Name
                $destination.Tag = @{ Path = $path; Id = $group.Id }
                $destination.Add_Click({
                    param($sender, $eventArgs)
                    Set-ShortcutPlacement $sender.Tag.Path $sender.Tag.Id '' $true
                })
                [void]$moveMenu.Items.Add($destination)
            }
            [void]$menu.Items.Add($moveMenu)
        }
        $launch = New-Object Windows.Controls.Button
        $launch.Style = $left.Resources['ShortcutIcon']
        $launch.Tag = $path
        $launch.ToolTip = $path
        $launch.ContextMenu = $menu
        $tile = New-Object Windows.Controls.StackPanel
        $icon = New-Object Windows.Controls.Image
        $icon.Source = Get-ShortcutIcon $path
        $icon.Width = $icon.Height = 38
        $icon.Margin = '0,0,0,6'
        [void]$tile.Children.Add($icon)
        $label = New-Object Windows.Controls.TextBlock
        $label.Text = [IO.Path]::GetFileNameWithoutExtension($path)
        $label.FontSize = 12
        $label.Width = 64
        $label.MaxHeight = 30
        $label.TextAlignment = 'Center'
        $label.TextWrapping = 'Wrap'
        $label.ToolTip = $label.Text
        $label.TextTrimming = 'WordEllipsis'
        [Windows.Automation.AutomationProperties]::SetName($launch, $label.Text)
        [void]$tile.Children.Add($label)
        $launch.Content = $tile
        $launch.Add_PreviewMouseLeftButtonDown({
            param($sender, $eventArgs)
            $script:dragStart = $eventArgs.GetPosition($folder)
        })
        $launch.Add_PreviewMouseLeftButtonUp({ $script:dragStart = $null })
        $launch.Add_PreviewMouseMove({
            param($sender, $eventArgs)
            if (!$script:dragStart -or $eventArgs.LeftButton -ne 'Pressed' -or $script:draggingShortcut) { return }
            $delta = $eventArgs.GetPosition($folder) - $script:dragStart
            if ([Math]::Abs($delta.X) -lt [Windows.SystemParameters]::MinimumHorizontalDragDistance -and
                [Math]::Abs($delta.Y) -lt [Windows.SystemParameters]::MinimumVerticalDragDistance) { return }
            $eventArgs.Handled = $true
            $script:dragStart = $null
            $script:draggingShortcut = $true
            $data = [Windows.DataObject]::new($dragFormat, [string]$sender.Tag)
            try {
                if ($sender.IsMouseCaptured) { $sender.ReleaseMouseCapture() }
                [void][Windows.DragDrop]::DoDragDrop($folder, $data, 'Move')
            } finally {
                $script:draggingShortcut = $false
                $folderHoverTimer.Stop()
                $script:hoverFolder = $null
                if (!$left.IsMouseOver) { $closeTimer.Start() }
            }
        })
        $launch.Add_Click({
            param($sender, $eventArgs)
            try {
                if ([IO.Path]::GetExtension($sender.Tag) -eq '.exe') {
                    Start-Process -FilePath $sender.Tag -WorkingDirectory ([IO.Path]::GetDirectoryName($sender.Tag))
                } else {
                    Start-Process -FilePath $sender.Tag
                }
            } catch {
                $hint.Text = 'Не удалось открыть ярлык.'
            }
        })
        [void]$shortcuts.Children.Add($launch)
    }
    $hint.Text = if ($script:moveError) { $script:moveError }
        elseif ($current -and !$script:visiblePaths.Count) { 'Перетащите ярлыки на эту папку.' }
        elseif ($current) { 'Перетаскивайте ярлыки, чтобы изменить порядок.' }
        else { 'Выберите ярлыки через «Добавить» или перетащите их сюда.' }
    $hint.TextWrapping = 'Wrap'
}

function Update-OutsideClick {
    $needed = ($folderTransition.Open -and !$script:state.pinned) -or $widgetTransition.Open
    $window = [Windows.Interop.WindowInteropHelper]::new($left).Handle
    $outsideClick.SetEnabled(($needed -and $window -ne [IntPtr]::Zero), $window)
}

function Dismiss-OutsideClick {
    if ($script:draggingShortcut -or $script:pickerOpen) { return }
    if ($folderTransition.Open -and !$script:state.pinned) {
        $openTimer.Stop()
        $closeTimer.Stop()
        $script:folderClickOpen = $false
        Set-Folder $false
    }
    if ($widgetTransition.Open) { Set-Panel $widgetTransition $false }
}

$outsideDispatcher = [Windows.Threading.DispatcherSynchronizationContext]::new($left.Dispatcher)
$outsideClick = [OutsidePanelClick]::new($outsideDispatcher, [Action]{ Dismiss-OutsideClick })
$left.Add_SourceInitialized({ Update-OutsideClick })

function Set-Panel($transition, [bool]$open) {
    if ($transition.Open -eq $open) { return }
    $transition.Open = $open
    Update-OutsideClick
    $transition.Version++
    $version = $transition.Version
    $panel = $transition.Panel
    if ($open) {
        $panel.Visibility = 'Visible'
        if ($transition.Window -and !$transition.Window.IsVisible) { $transition.Window.Show() }
    }
    $panel.IsHitTestVisible = $open
    $opacity = if ($open) { 1.0 } else { 0.0 }
    $offset = if ($open) { 0.0 } else { $transition.Offset }
    if (![Windows.SystemParameters]::ClientAreaAnimation) {
        $panel.Opacity = $opacity
        $panel.RenderTransform.X = $offset
        if (!$open) {
            if ($transition.Window) { $transition.Window.Hide() }
            else { $panel.Visibility = 'Collapsed' }
        }
        return
    }

    $duration = [Windows.Duration]::new([TimeSpan]::FromMilliseconds($(if ($open) { 240 } else { 170 })))
    $ease = New-Object Windows.Media.Animation.CubicEase
    $ease.EasingMode = 'EaseOut'
    $slide = [Windows.Media.Animation.DoubleAnimation]::new($panel.RenderTransform.X, $offset, $duration)
    $slide.EasingFunction = $ease
    $fade = [Windows.Media.Animation.DoubleAnimation]::new($panel.Opacity, $opacity, $duration)
    $fade.EasingFunction = $ease
    if (!$open) {
        $fade.Add_Completed({
            if ($transition.Version -ne $version) { return }
            if ($transition.Window) { $transition.Window.Hide() }
            else { $panel.Visibility = 'Collapsed' }
        }.GetNewClosure())
    }
    $panel.RenderTransform.BeginAnimation([Windows.Media.TranslateTransform]::XProperty, $slide)
    $panel.BeginAnimation([Windows.UIElement]::OpacityProperty, $fade)
}

function Set-Folder([bool]$open) {
    Set-Panel $folderTransition $open
}

$script:folderClickOpen = $false

function Set-Pin([bool]$pinned) {
    $script:state.pinned = $pinned
    $script:folderClickOpen = $false
    Update-OutsideClick
    $pin.Content = if ($pinned) { 'Открепить' } else { 'Закрепить' }
    $pin.Background = if ($pinned) { '#D6EBE1' } else { '#EAF3EE' }
}

$openTimer = New-Object Windows.Threading.DispatcherTimer
$openTimer.Interval = [TimeSpan]::FromMilliseconds(350)
$openTimer.Add_Tick({
    $openTimer.Stop()
    Set-Folder $true
})
$closeTimer = New-Object Windows.Threading.DispatcherTimer
$closeTimer.Interval = [TimeSpan]::FromMilliseconds(250)
$closeTimer.Add_Tick({
    $closeTimer.Stop()
    if ($script:draggingShortcut -or $script:pickerOpen -or $script:folderClickOpen) { return }
    if (!$left.IsMouseOver -and !$script:state.pinned -and !$shortcuts.IsMouseCaptureWithin) {
        foreach ($shortcut in $shortcuts.Children) {
            if ($shortcut.ContextMenu.IsOpen) { $closeTimer.Start(); return }
        }
        Set-Folder $false
    }
})
$handle = $left.FindName('Handle')
$handle.Add_MouseEnter({ $openTimer.Start() })
$handle.Add_MouseLeave({ $openTimer.Stop() })
$handle.AllowDrop = $true
$handle.Add_PreviewDragOver({
    param($sender, $eventArgs)
    if ($eventArgs.Data.GetDataPresent([Windows.DataFormats]::FileDrop) -and !$folderTransition.Open) {
        $openTimer.Start()
    }
    $eventArgs.Effects = 'None'
    $eventArgs.Handled = $true
})
$handle.Add_DragLeave({ $openTimer.Stop() })
$handle.Add_Click({
    $openTimer.Stop()
    $closeTimer.Stop()
    if (!$script:state.pinned) {
        # A click confirms a hover-opened panel without turning it into a saved pin.
        $script:folderClickOpen = !$script:folderClickOpen
        Set-Folder $script:folderClickOpen
    }
})
$left.Add_MouseEnter({ $closeTimer.Stop() })
$left.Add_MouseLeave({ $closeTimer.Start() })
$pin.Add_Click({
    Set-Pin (!$script:state.pinned)
    Save-State
})

function Get-DropButton($element) {
    while ($element -and $element -ne $folder) {
        if ($element -is [Windows.Controls.Button] -and $element.Tag) { return $element }
        if ($element -is [Windows.Media.Visual]) {
            $element = [Windows.Media.VisualTreeHelper]::GetParent($element)
        } else {
            $element = [Windows.LogicalTreeHelper]::GetParent($element)
        }
    }
}

$folderHoverTimer = New-Object Windows.Threading.DispatcherTimer
$folderHoverTimer.Interval = [TimeSpan]::FromMilliseconds(400)
$folderHoverTimer.Add_Tick({
    $folderHoverTimer.Stop()
    if ($script:draggingShortcut -and $null -ne $script:hoverFolder) {
        Select-ShortcutFolder $script:hoverFolder
    }
})
$folder.Add_DragLeave({
    $folderHoverTimer.Stop()
    $script:hoverFolder = $null
})

$left.FindName('NewFolder').Add_Click({
    $editor.Visibility = if ($editor.Visibility -eq 'Visible') { 'Collapsed' } else { 'Visible' }
    if ($editor.Visibility -eq 'Visible') { [void]$folderName.Focus() }
})
function Submit-ShortcutFolder {
    if (Add-ShortcutFolder $folderName.Text) {
        $folderName.Clear()
        $editor.Visibility = 'Collapsed'
    } else {
        $hint.Text = 'Введите уникальное название папки.'
    }
}
$left.FindName('CreateFolder').Add_Click({ Submit-ShortcutFolder })
$folderName.Add_KeyDown({
    param($sender, $eventArgs)
    if ($eventArgs.Key -eq 'Enter') { Submit-ShortcutFolder; $eventArgs.Handled = $true }
})

function Get-DesktopChoices {
    foreach ($directory in @($desktopPath, $publicDesktopPath) | Select-Object -Unique) {
        if (!$directory) { continue }
        Get-ChildItem -LiteralPath $directory -File -ErrorAction SilentlyContinue |
            Where-Object { Get-DesktopOrigin $_.FullName } |
            Sort-Object Name
    }
}

function Show-DesktopPicker {
    $picker = New-Overlay @'
<Border Background="#F8FCF9" CornerRadius="22" BorderBrush="{StaticResource Stroke}" BorderThickness="1" Padding="19" Width="435">
 <StackPanel>
  <TextBlock Text="Добавить ярлыки" FontSize="23" FontWeight="SemiBold" Margin="0,0,0,4"/>
  <TextBlock x:Name="Destination" Foreground="{StaticResource Muted}" TextTrimming="CharacterEllipsis" Margin="0,0,0,12"/>
  <ListBox x:Name="Choices" SelectionMode="Extended" Height="228" Padding="3" BorderBrush="{StaticResource Stroke}" AutomationProperties.Name="Ярлыки рабочего стола"/>
  <TextBlock Text="Общие ярлыки видны всем пользователям этого ПК." Foreground="{StaticResource Muted}" FontSize="12" TextWrapping="Wrap" Margin="0,9,0,12"/>
  <DockPanel>
   <Button x:Name="All" Content="Выбрать все" DockPanel.Dock="Left"/>
   <Button x:Name="Add" Content="Переместить" Background="#D6EBE1" DockPanel.Dock="Right" IsDefault="True" IsEnabled="False"/>
   <Button Content="Отмена" IsCancel="True" HorizontalAlignment="Right" Margin="0,0,7,0"/>
  </DockPanel>
 </StackPanel>
</Border>
'@
    $picker.Owner = $left
    $picker.WindowStartupLocation = 'CenterScreen'
    $target = $script:activeFolder
    $picker.FindName('Destination').Text = 'Куда: ' + $folderTitle.Text
    $list = $picker.FindName('Choices')
    $submit = $picker.FindName('Add')
    foreach ($file in @(Get-DesktopChoices)) {
        $item = New-Object Windows.Controls.ListBoxItem
        $original = if ((Get-DesktopOrigin $file.FullName) -eq 'Public') { 'общий' } else { 'личный' }
        $item.Content = if ($file.Extension -eq '.exe') { "$($file.Name)  ·  файл приложения" }
            else { "$($file.BaseName)  ·  $original" }
        $item.Tag = $file.FullName
        $item.Padding = '8,5'
        [void]$list.Items.Add($item)
    }
    $picker.FindName('All').IsEnabled = $list.Items.Count -gt 0
    $picker.FindName('All').Add_Click({ $list.SelectAll() })
    $list.Add_SelectionChanged({ $submit.IsEnabled = $list.SelectedItems.Count -gt 0 })
    $submit.Add_Click({ $picker.DialogResult = $true })
    $script:pickerOpen = $true
    try {
        if ($picker.ShowDialog()) {
            Add-Shortcuts @($list.SelectedItems | ForEach-Object Tag) $target
        }
    } finally { $script:pickerOpen = $false }
}
$left.FindName('AddDesktop').Add_Click({ Show-DesktopPicker })

function Get-SafeExternalDropEffect($allowed) {
    if ($allowed -band [Windows.DragDropEffects]::Copy) { return [Windows.DragDropEffects]::Copy }
    if ($allowed -band [Windows.DragDropEffects]::Link) { return [Windows.DragDropEffects]::Link }
    [Windows.DragDropEffects]::None
}

$folder.Add_PreviewDragOver({
    param($sender, $eventArgs)
    $eventArgs.Effects = 'None'
    if ($script:draggingShortcut -and $eventArgs.Data.GetDataPresent($dragFormat)) {
        $button = Get-DropButton $eventArgs.OriginalSource
        $hover = if ($button -and $button.Tag -isnot [string]) { [string]$button.Tag.Id } else { $null }
        if ($null -eq $hover -or $hover -ne $script:hoverFolder) {
            $folderHoverTimer.Stop()
            $script:hoverFolder = $hover
            if ($null -ne $hover -and $hover -ne $script:activeFolder) { $folderHoverTimer.Start() }
        }
        if ($null -ne $hover -or $button -or
            $eventArgs.OriginalSource -eq $shortcuts) { $eventArgs.Effects = 'Move' }
    } elseif ($eventArgs.Data.GetDataPresent([Windows.DataFormats]::FileDrop)) {
        $eventArgs.Effects = Get-SafeExternalDropEffect $eventArgs.AllowedEffects
    }
    $eventArgs.Handled = $true
})
$folder.Add_PreviewDrop({
    param($sender, $eventArgs)
    if ($script:draggingShortcut -and $eventArgs.Data.GetDataPresent($dragFormat)) {
        $path = $eventArgs.Data.GetData($dragFormat)
        $button = Get-DropButton $eventArgs.OriginalSource
        $eventArgs.Effects = 'None'
        if ($button -and $button.Tag -isnot [string]) {
            Set-ShortcutPlacement $path $button.Tag.Id '' $true
            Select-ShortcutFolder $button.Tag.Id
            $eventArgs.Effects = 'Move'
        } elseif ($button -or $eventArgs.OriginalSource -eq $shortcuts) {
            $before = if ($button) { $button.Tag } else { '' }
            if ($button -and $before -ne $path -and $eventArgs.GetPosition($button).X -gt $button.ActualWidth / 2) {
                $items = @($script:visiblePaths | Where-Object { $_ -ne $path })
                $index = [Array]::IndexOf($items, $before) + 1
                $before = if ($index -lt $items.Count) { $items[$index] } else { '' }
            }
            Set-ShortcutPlacement $path $script:activeFolder $before ([bool]$script:activeFolder)
            $eventArgs.Effects = 'Move'
        }
        $eventArgs.Handled = $true
    } elseif ($eventArgs.Data.GetDataPresent([Windows.DataFormats]::FileDrop)) {
        # The app owns the physical move, so Explorer must not also delete the source.
        $eventArgs.Handled = $true
        $eventArgs.Effects = Get-SafeExternalDropEffect $eventArgs.AllowedEffects
        if ($eventArgs.Effects -ne 'None') {
            $button = Get-DropButton $eventArgs.OriginalSource
            $target = if ($button -and $button.Tag -isnot [string]) { $button.Tag.Id } else { $script:activeFolder }
            Add-Shortcuts $eventArgs.Data.GetData([Windows.DataFormats]::FileDrop) $target
            if ($target -ne $script:activeFolder) { Select-ShortcutFolder $target }
        }
    }
})

$noteTimer = New-Object Windows.Threading.DispatcherTimer
$noteTimer.Interval = [TimeSpan]::FromMilliseconds(300)
$noteTimer.Add_Tick({
    $noteTimer.Stop()
    Save-State
})
$note.Add_TextChanged({
    $script:state.note = $note.Text
    $noteTimer.Stop()
    $noteTimer.Start()
})

if ($UpdateReady) {
    $left.Add_ContentRendered({
        if ($script:updateReadyReported) { return }
        $UpdateReady.Invoke()
        $script:updateReadyReported = $true
    })
}

if ($EnableUpdates) {
    $updateButton = $left.FindName('Update')
    $updateTimer = New-Object Windows.Threading.DispatcherTimer
    $updateTimer.Interval = [TimeSpan]::FromMilliseconds(350)
    $script:updateCheck = [NewLookUpdate]::CheckAsync()
    $script:updateDownload = $null
    $script:updateInstall = $null
    $script:updatePackage = $null
    $script:preparedUpdate = $null
    $updateButton.Add_Click({
        $updateButton.IsEnabled = $false
        $updateButton.Content = 'Загрузка…'
        $script:updateDownload = [NewLookUpdate]::DownloadAsync($script:updatePackage)
        $updateTimer.Interval = [TimeSpan]::FromMilliseconds(350)
    })
    $updateTimer.Add_Tick({
        try {
            if ($script:updateDownload) {
                if (!$script:updateDownload.IsCompleted) { return }
                $script:preparedUpdate = $script:updateDownload.GetAwaiter().GetResult()
                $script:updateDownload = $null
                if ($noteTimer.IsEnabled) {
                    Save-State
                    $noteTimer.Stop()
                }
                $left.IsEnabled = $false
                $right.IsEnabled = $false
                $updateButton.Content = 'Установка…'
                $script:updateInstall = [NewLookUpdate]::InstallAsync($script:preparedUpdate)
            } elseif ($script:updateInstall) {
                if (!$script:updateInstall.IsCompleted) { return }
                $script:updateInstall.GetAwaiter().GetResult()
                $updateTimer.Stop()
                $left.Close()
            } elseif ($script:updateCheck) {
                if (!$script:updateCheck.IsCompleted) { return }
                try { $script:updatePackage = $script:updateCheck.GetAwaiter().GetResult() } catch {}
                $script:updateCheck = $null
                if ($script:updatePackage) {
                    $updateButton.Visibility = 'Visible'
                    $updateButton.ToolTip = 'Версия ' + $script:updatePackage.Version.ToString(3)
                } else {
                    $updateButton.Visibility = 'Collapsed'
                }
                $updateTimer.Interval = [TimeSpan]::FromHours(4)
            } else {
                $script:updateCheck = [NewLookUpdate]::CheckAsync()
                $updateTimer.Interval = [TimeSpan]::FromMilliseconds(350)
            }
        } catch {
            [NewLookUpdate]::Discard($script:preparedUpdate)
            $script:preparedUpdate = $null
            $script:updateDownload = $null
            $script:updateInstall = $null
            $left.IsEnabled = $true
            $right.IsEnabled = $true
            $updateButton.Content = 'Обновить'
            $updateButton.IsEnabled = $true
            $updateTimer.Interval = [TimeSpan]::FromHours(4)
            [void][Windows.MessageBox]::Show($left, $_.Exception.GetBaseException().Message, 'Обновление Shelfside', 'OK', 'Warning')
        }
    })
    $updateTimer.Start()
}

$workArea = [Windows.SystemParameters]::WorkArea
$left.Left = $workArea.Left
$left.Add_SizeChanged({ $left.Top = $workArea.Top + [Math]::Max(0, ($workArea.Height - $left.ActualHeight) / 2) })
$right.Add_SizeChanged({
    $right.Left = $workArea.Right - $right.ActualWidth - 12
    $right.Top = $workArea.Top + [Math]::Max(0, ($workArea.Height - $right.ActualHeight) / 2)
})
$widgets = $left.FindName('Widgets')
$widgets.Add_Click({ Set-Panel $widgetTransition (!$widgetTransition.Open) })
$right.FindName('CloseWidgets').Add_Click({ Set-Panel $widgetTransition $false })
$menu = New-Object Windows.Controls.ContextMenu
$exitItem = New-Object Windows.Controls.MenuItem
$exitItem.Header = 'Выйти из Shelfside'
$exitItem.Add_Click({ $left.Close() })
[void]$menu.Items.Add($exitItem)
$handle.ContextMenu = $menu
$left.Add_Closed({
    $outsideClick.Dispose()
    $widgetTransition.Version++
    if ($noteTimer.IsEnabled) {
        $noteTimer.Stop()
        Save-State
    }
    $right.Close()
})

Set-Pin $script:state.pinned
Set-Folder $script:state.pinned
Show-FolderTabs

if ($SmokeTest) {
    function Wait-SmokeDispatcher([int]$milliseconds) {
        $probeFrame = New-Object Windows.Threading.DispatcherFrame
        $timer = New-Object Windows.Threading.DispatcherTimer
        $timer.Interval = [TimeSpan]::FromMilliseconds($milliseconds)
        $timer.Add_Tick({ $probeFrame.Continue = $false }.GetNewClosure())
        $timer.Start()
        [Windows.Threading.Dispatcher]::PushFrame($probeFrame)
        $timer.Stop()
    }
    function Send-SmokeMouseEvent($element, $event) {
        $mouseEvent = [Windows.Input.MouseEventArgs]::new([Windows.Input.Mouse]::PrimaryDevice, 0)
        $mouseEvent.RoutedEvent = $event
        $element.RaiseEvent($mouseEvent)
    }
    try {
        [void][IO.Directory]::CreateDirectory($testRoot)
        if ($BrandIcon -and ($left.Icon.PixelWidth -ne 256 -or $right.Icon.PixelWidth -ne 256)) {
            throw 'Shelfside window icon did not load.'
        }
        [void][IO.Directory]::CreateDirectory($desktopPath)
        [void][IO.Directory]::CreateDirectory($publicDesktopPath)
        $sample = Join-Path $testRoot 'Example.url'
        $sampleLink = Join-Path $testRoot 'Notepad.lnk'
        $desktopLink = Join-Path $desktopPath 'Desktop.url'
        $storedLink = Join-Path $storagePath 'Desktop.url'
        [IO.File]::WriteAllText($sample, "[InternetShortcut]`r`nURL=https://example.com")
        $shell = New-Object -ComObject WScript.Shell
        $link = $shell.CreateShortcut($sampleLink)
        $link.TargetPath = Join-Path $env:WINDIR 'notepad.exe'
        $link.Save()
        $left.Show()
        Wait-SmokeDispatcher 100
        $railPosition = $handle.PointToScreen([Windows.Point]::new(0, 0))
        $enter = [Windows.UIElement]::MouseEnterEvent
        $leave = [Windows.UIElement]::MouseLeaveEvent
        Send-SmokeMouseEvent $handle $enter
        Wait-SmokeDispatcher 470
        if (!$folderTransition.Open -or $folder.Visibility -ne 'Visible') { throw 'Hover timer did not open the shortcut folder' }
        if ($handle.PointToScreen([Windows.Point]::new(0, 0)) -ne $railPosition) { throw 'Opening the panel moved its handle' }
        Send-SmokeMouseEvent $left $leave
        Send-SmokeMouseEvent $left $enter
        Wait-SmokeDispatcher 460
        if (!$folderTransition.Open) { throw 'Pointer crossing onto the panel did not cancel auto-close' }
        Send-SmokeMouseEvent $left $leave
        Wait-SmokeDispatcher 460
        if ($folder.Visibility -ne 'Collapsed') { throw 'Hover-only panel did not close after leaving' }
        Send-SmokeMouseEvent $handle $enter
        Wait-SmokeDispatcher 470
        $handle.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
        if (!$folderTransition.Open) { throw 'A click after hover closed the shortcut folder' }
        Send-SmokeMouseEvent $left $leave
        Wait-SmokeDispatcher 460
        if (!$folderTransition.Open) { throw 'The click-open panel closed after leaving' }
        $handle.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
        Wait-SmokeDispatcher 460
        if ($folder.Visibility -ne 'Collapsed') { throw 'A second click did not close the shortcut folder' }
        Send-SmokeMouseEvent $handle $enter
        $handle.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
        Wait-SmokeDispatcher 470
        if (!$folderTransition.Open -or $openTimer.IsEnabled) { throw 'Fast click did not open or left a pending hover timer' }
        Set-Pin $true
        Send-SmokeMouseEvent $left $leave
        $handle.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
        Wait-SmokeDispatcher 460
        if (!$folderTransition.Open) { throw 'A pinned panel closed on pointer leave or a click' }
        Set-Pin $false
        Send-SmokeMouseEvent $left $leave
        Wait-SmokeDispatcher 460
        if ($folder.Visibility -ne 'Collapsed') { throw 'An unpinned panel did not dismiss' }
        $handle.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))

        $frame = New-Object Windows.Threading.DispatcherFrame
        $probeTimer = New-Object Windows.Threading.DispatcherTimer
        $probeTimer.Interval = [TimeSpan]::FromMilliseconds(450)
        $probeTimer.Add_Tick({ $frame.Continue = $false })
        Add-Shortcuts @($sample, $sample, $sampleLink, $statePath)
        if ($shortcuts -isnot [Windows.Controls.WrapPanel] -or
            $shortcuts.Children.Count -ne 2 -or
            !$shortcuts.Children[0].Content.Children[0].Source -or
            !$shortcuts.Children[1].Content.Children[0].Source) { throw 'Shortcut grid did not load the Shell icons' }
        if (!(Add-ShortcutFolder 'Work') -or !(Add-ShortcutFolder 'Personal') -or (Add-ShortcutFolder 'work')) {
            throw 'Folder creation or duplicate name check failed'
        }
        $work = $script:state.folders[0].Id
        $personal = $script:state.folders[1].Id
        Set-ShortcutPlacement $sample $work '' $true
        Set-ShortcutPlacement $sampleLink $work '' $true
        $script:draggingShortcut = $true
        $script:hoverFolder = $work
        $folderHoverTimer.Start()
        $frame = New-Object Windows.Threading.DispatcherFrame
        $probeTimer.Start()
        [Windows.Threading.Dispatcher]::PushFrame($frame)
        $probeTimer.Stop()
        $script:draggingShortcut = $false
        $script:hoverFolder = $null
        if ($script:activeFolder -ne $work -or $shortcuts.Children.Count -ne 2) { throw 'Hover did not open the target folder' }
        Set-ShortcutPlacement $sampleLink $work $sample $true
        $script:state = Read-State
        Show-FolderTabs
        if ($shortcuts.Children[0].Tag -ne $sampleLink) { throw 'Folder order was not restored' }
        Set-ShortcutPlacement $sampleLink $personal '' $true
        if ($sampleLink -in $script:state.folders[0].items -or
            $sampleLink -notin $script:state.folders[1].items) { throw 'Moving between folders duplicated or lost the shortcut' }
        Set-ShortcutPlacement $sampleLink '' '' $true
        Select-ShortcutFolder ''
        if ($sampleLink -in $script:state.folders[1].items -or $shortcuts.Children.Count -ne 2) {
            throw 'Returning to All shortcuts did not clear folder membership'
        }
        $shortcuts.Children[1].ContextMenu.Items[0].RaiseEvent(
            [Windows.RoutedEventArgs]::new([Windows.Controls.MenuItem]::ClickEvent))
        if ($shortcuts.Children.Count -ne 1 -or !(Test-Path -LiteralPath $sampleLink)) { throw 'Shortcut removal did not preserve the source file' }
        [IO.File]::Copy($sample, $desktopLink)
        $script:state.shortcuts += $desktopLink
        Save-State
        $script:state = Read-State
        Show-Shortcuts
        if (!(Test-Path -LiteralPath $desktopLink) -or (Test-Path -LiteralPath $storedLink)) { throw 'A legacy reference was migrated automatically' }
        $shortcuts.Children[1].ContextMenu.Items[0].RaiseEvent(
            [Windows.RoutedEventArgs]::new([Windows.Controls.MenuItem]::ClickEvent))
        $script:state = Read-State
        Show-Shortcuts
        if ((Test-Path -LiteralPath $desktopLink) -or !(Test-Path -LiteralPath $storedLink) -or
            $shortcuts.Children[0].Tag -ne $storedLink -or $desktopLink -in $script:state.shortcuts) {
            throw 'Explicit migration did not move and rediscover the shortcut'
        }
        [IO.File]::WriteAllText($desktopLink, 'untouched')
        Add-Shortcuts @($desktopLink)
        if (!$script:moveError -or [IO.File]::ReadAllText($desktopLink) -ne 'untouched' -or
            [IO.File]::ReadAllText($storedLink) -ne [IO.File]::ReadAllText($sample)) {
            throw 'Storage collision did not preserve both originals'
        }
        $return = $shortcuts.Children[0].ContextMenu.Items[0]
        $return.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.MenuItem]::ClickEvent))
        if (!$script:moveError -or [IO.File]::ReadAllText($desktopLink) -ne 'untouched' -or
            !(Test-Path -LiteralPath $storedLink)) { throw 'Desktop collision did not preserve both originals' }
        [IO.File]::Delete($desktopLink)
        $return.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.MenuItem]::ClickEvent))
        if ((Test-Path -LiteralPath $storedLink) -or
            [IO.File]::ReadAllText($desktopLink) -ne [IO.File]::ReadAllText($sample)) { throw 'Return did not restore the shortcut' }
        Add-Shortcuts @($desktopLink)
        if ((Test-Path -LiteralPath $desktopLink) -or !(Test-Path -LiteralPath $storedLink)) { throw 'Drop did not move the desktop shortcut' }
        $publicLink = Join-Path $publicDesktopPath 'Shared.lnk'
        $privateLink = Join-Path $desktopPath 'Shared.lnk'
        $personalApp = Join-Path $desktopPath 'TestApp.exe'
        $storedPublic = Join-Path $publicStoragePath 'Shared.lnk'
        $storedPrivate = Join-Path $storagePath 'Shared.lnk'
        $storedApp = Join-Path $storagePath 'TestApp.exe'
        [IO.File]::Copy($sampleLink, $publicLink)
        [IO.File]::Copy($sampleLink, $privateLink)
        [IO.File]::Copy($sample, $desktopLink)
        [IO.File]::Copy((Join-Path $env:WINDIR 'notepad.exe'), $personalApp)
        $appBytes = [Convert]::ToBase64String([IO.File]::ReadAllBytes($personalApp))
        Select-ShortcutFolder $work
        $pickerProbe = New-Object Windows.Threading.DispatcherTimer
        $pickerProbe.Interval = [TimeSpan]::FromMilliseconds(120)
        $script:pickerProblem = $null
        $pickerProbe.Add_Tick({
            $pickerProbe.Stop()
            $popup = @($left.OwnedWindows)[0]
            try {
                $choices = $popup.FindName('Choices')
                if ($choices.Items.Count -ne 4 -or $choices.Items.Tag -notcontains $publicLink -or
                    $choices.Items.Tag -notcontains $privateLink -or $choices.Items.Tag -notcontains $personalApp) {
                    throw 'Picker did not list both desktops and the application file.'
                }
                $popup.FindName('All').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
                if ($choices.SelectedItems.Count -ne 4 -or !$popup.FindName('Add').IsEnabled) { throw 'Picker did not select all items.' }
                $popup.FindName('Add').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
            } catch {
                $script:pickerProblem = $_
            } finally { if ($popup -and $popup.IsVisible) { $popup.Close() } }
        })
        $pickerProbe.Start()
        $left.FindName('AddDesktop').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
        if ($script:pickerProblem) { throw $script:pickerProblem }
        if ((Test-Path -LiteralPath $publicLink) -or (Test-Path -LiteralPath $privateLink) -or
            !(Test-Path -LiteralPath $desktopLink) -or $storedPublic -notin $script:state.folders[0].items -or
            $storedPrivate -notin $script:state.folders[0].items -or $storedApp -notin $script:state.folders[0].items -or
            (Test-Path -LiteralPath $personalApp) -or [Convert]::ToBase64String([IO.File]::ReadAllBytes($storedApp)) -ne $appBytes -or
            $script:moveError -notmatch 'Не удалось: 1') {
            throw 'Batch did not move both origins and the application file to the selected folder.'
        }
        $returnShared = ($shortcuts.Children | Where-Object Tag -eq $storedPublic).ContextMenu.Items[0]
        $returnShared.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.MenuItem]::ClickEvent))
        if (!(Test-Path -LiteralPath $publicLink) -or (Test-Path -LiteralPath $storedPublic) -or
            !(Test-Path -LiteralPath $storedPrivate)) { throw 'Shared shortcut was not returned to its original desktop.' }
        $returnApp = ($shortcuts.Children | Where-Object Tag -eq $storedApp).ContextMenu.Items[0]
        $returnApp.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.MenuItem]::ClickEvent))
        if ((Test-Path -LiteralPath $storedApp) -or [Convert]::ToBase64String([IO.File]::ReadAllBytes($personalApp)) -ne $appBytes) {
            throw 'The application file did not return intact.'
        }
        $data = [Windows.DataObject]::new([Windows.DataFormats]::FileDrop, [string[]]@($publicLink, $personalApp))
        $dragConstructor = [Windows.DragEventArgs].GetConstructors([Reflection.BindingFlags]'NonPublic,Instance')[0]
        $drop = $dragConstructor.Invoke(@($data, [Windows.DragDropKeyStates]::None, [Windows.DragDropEffects]::Link, $folder, [Windows.Point]::new(1, 1)))
        $drop.RoutedEvent = [Windows.DragDrop]::PreviewDropEvent
        $folder.RaiseEvent($drop)
        if (!$drop.Handled -or $drop.Effects -ne 'Link' -or (Test-Path -LiteralPath $publicLink) -or
            (Test-Path -LiteralPath $personalApp) -or !(Test-Path -LiteralPath $storedPublic) -or
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($storedApp)) -ne $appBytes) { throw 'Routed external drop did not move both files safely.' }
        $pin.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
        $widgets.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
        if (!$right.IsVisible) { throw 'Widget panel did not open' }
        $note.Text = 'Saved note'
        $right.FindName('CloseWidgets').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
        $widgets.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
        if (!$widgetTransition.Open) { throw 'Widget panel did not reverse a closing transition' }
        $frame = New-Object Windows.Threading.DispatcherFrame
        $probeTimer.Start()
        [Windows.Threading.Dispatcher]::PushFrame($frame)
        $probeTimer.Stop()
        if (!$right.IsVisible -or [Math]::Abs($widgetPanel.Opacity - 1) -gt 0.01) { throw 'Reopened widget panel did not settle open' }
        $calendar = $right.FindName('Calendar')
        $calendarItem = $calendar.Template.FindName('PART_CalendarItem', $calendar)
        $nextMonth = $calendarItem.Template.FindName('PART_NextButton', $calendarItem)
        $monthHeader = $calendarItem.Template.FindName('PART_HeaderButton', $calendarItem)
        $expectedMonth = $calendar.DisplayDate.AddMonths(1).Month
        $nextMonth.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
        if ($calendar.DisplayDate.Month -ne $expectedMonth) { throw 'Calendar next month did not work' }
        $monthHeader.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
        if ($calendar.DisplayMode -ne 'Year') { throw 'Calendar year view did not open' }
        $right.FindName('CloseWidgets').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
        $frame = New-Object Windows.Threading.DispatcherFrame
        $probeTimer.Start()
        [Windows.Threading.Dispatcher]::PushFrame($frame)
        $probeTimer.Stop()
        if ($right.IsVisible) { throw 'Widget panel did not close' }
        $left.Close()
        $restored = Read-State
        if (@($restored.shortcuts).Count -ne 1 -or $restored.shortcuts[0] -ne $sample -or
            !$restored.pinned -or $restored.note -ne 'Saved note') { throw 'Saved state did not round trip' }
        'PASS: picker and routed drop for shared .lnk and personal .exe, shell moves and return, conflicts, byte preservation and panel regressions'
    } finally {
        $fixtures = @($sample, $sampleLink, $statePath, "$statePath.tmp", "$statePath.bak", $desktopLink, $storedLink,
            $publicLink, $privateLink, $storedPublic, $storedPrivate, $personalApp, $storedApp) | Where-Object { $_ }
        Remove-Item -LiteralPath $fixtures -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $desktopPath, $publicDesktopPath, $publicStoragePath, $storagePath -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $testRoot -ErrorAction SilentlyContinue
    }
} else {
    [void]$left.ShowDialog()
}
