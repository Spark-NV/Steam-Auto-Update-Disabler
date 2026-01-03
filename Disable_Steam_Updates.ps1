#Requires -Version 5.1

$ScriptVersion = "1.0"

try {
    [void][System.Reflection.Assembly]::LoadWithPartialName('WindowsBase')
    [void][System.Reflection.Assembly]::LoadWithPartialName('PresentationCore')
    [void][System.Reflection.Assembly]::LoadWithPartialName('PresentationFramework')
    [void][System.Reflection.Assembly]::LoadWithPartialName('System.Xaml')
} catch {
    Add-Type -AssemblyName WindowsBase, PresentationCore, PresentationFramework, System.Xaml
}

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO",
        [switch]$NoNewline
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"

    if ($NoNewline) {
        Write-Host $logMessage -NoNewline
    } else {
        Write-Host $logMessage
    }
}

function Get-SteamInstallPath {
    try {
        $steamPath = Get-ItemProperty -Path "HKCU:\Software\Valve\Steam" -Name "SteamPath" -ErrorAction SilentlyContinue
        if ($steamPath) {
            Write-Log "Found Steam installation at: $($steamPath.SteamPath)"
            return $steamPath.SteamPath
        }

        $steamPath = Get-ItemProperty -Path "HKLM:\SOFTWARE\Valve\Steam" -Name "InstallPath" -ErrorAction SilentlyContinue
        if ($steamPath) {
            Write-Log "Found Steam installation at: $($steamPath.InstallPath)"
            return $steamPath.InstallPath
        }

        $steamPath = Get-ItemProperty -Path "HKLM:\SOFTWARE\WOW6432Node\Valve\Steam" -Name "InstallPath" -ErrorAction SilentlyContinue
        if ($steamPath) {
            Write-Log "Found Steam installation at: $($steamPath.InstallPath)"
            return $steamPath.InstallPath
        }

        Write-Log "Steam installation not found in registry" -Level "ERROR"
        throw "Steam installation not found in registry"
    }
    catch {
        Write-Log "Unable to find Steam installation directory: $($_.Exception.Message)" -Level "ERROR"
        throw "Unable to find Steam installation directory. Please ensure Steam is installed."
    }
}

function Get-SteamLibraryPaths {
    param([string]$SteamPath)

    Write-Log "Scanning Steam library folders..."
    $libraryFoldersPath = Join-Path $SteamPath "steamapps\libraryfolders.vdf"
    if (!(Test-Path $libraryFoldersPath)) {
        Write-Log "libraryfolders.vdf not found at $libraryFoldersPath" -Level "ERROR"
        throw "libraryfolders.vdf not found at $libraryFoldersPath"
    }

    $content = Get-Content $libraryFoldersPath -Raw
    $libraries = @()

    $libraries += Join-Path $SteamPath "steamapps"

    $pathMatches = [regex]::Matches($content, '"path"\s*"([^"]+)"')
    foreach ($match in $pathMatches) {
        $path = $match.Groups[1].Value.Replace("\\", "\")
        $fullPath = Join-Path $path "steamapps"
        $libraries += $fullPath
    }

    $normalizedLibraries = @{}
    foreach ($lib in ($libraries | Where-Object { Test-Path $_ })) {
        $normalizedPath = [System.IO.Path]::GetFullPath($lib)
        $normalizedLibraries[$normalizedPath.ToLower()] = $normalizedPath
    }
    $validLibraries = $normalizedLibraries.Values
    $libraryPaths = $validLibraries -join ", "
    Write-Log "Found $($validLibraries.Count) valid Steam libraries: $libraryPaths"
    return $validLibraries
}

function Get-SteamApps {
    param([string[]]$LibraryPaths)

    Write-Log "Loading game manifests from $($LibraryPaths.Count) Steam libraries..."
    $apps = @()
    $totalFiles = 0

    foreach ($libraryPath in $LibraryPaths) {
        $acfFiles = Get-ChildItem -Path $libraryPath -Filter "appmanifest_*.acf" -ErrorAction SilentlyContinue
        Write-Log "Found $($acfFiles.Count) manifest files in $libraryPath"
        $totalFiles += $acfFiles.Count

        foreach ($acfFile in $acfFiles) {
            try {
                $content = Get-Content $acfFile.FullName -Raw
                $appid = [regex]::Match($content, '"appid"\s*"(\d+)"').Groups[1].Value
                $name = [regex]::Match($content, '"name"\s*"([^"]+)"').Groups[1].Value

                if ($appid -and $name) {
                    $isReadOnly = (Get-Item $acfFile.FullName).IsReadOnly
                    $apps += [PSCustomObject]@{
                        AppId = $appid
                        Name = $name
                        ManifestPath = $acfFile.FullName
                        IsUpdateDisabled = $isReadOnly
                        LibraryPath = $libraryPath
                    }
                } else {
                    Write-Log "Skipping malformed manifest: $($acfFile.Name)" -Level "WARN"
                }
            }
            catch {
                Write-Log "Error parsing manifest $($acfFile.Name): $($_.Exception.Message)" -Level "WARN"
                continue
            }
        }
    }

    Write-Log "Successfully loaded $($apps.Count) games from $totalFiles manifest files"
    return $apps
}
function Set-UpdateStatus {
    param(
        [string]$ManifestPath,
        [bool]$DisableUpdates
    )

    try {
        $item = Get-Item $ManifestPath
        $item.IsReadOnly = $DisableUpdates
        $statusText = if ($DisableUpdates) { "readonly" } else { "Read/Write" }
        Write-Log "Successfully set manifest to $statusText"
        return $true
    }
    catch {
        Write-Log "Failed to update manifest status: $($_.Exception.Message)" -Level "ERROR"
        return $false
    }
}

$XAML = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Steam Update Manager"
        Height="700"
        Width="1200"
        WindowStartupLocation="CenterScreen"
        Background="#1e1e2e"
        FontFamily="Segoe UI"
        FontSize="12"
        ResizeMode="CanResize"
        MinWidth="1100"
        MinHeight="750">

    <Window.Resources>
        <Style x:Key="ColumnHeaderStyle" TargetType="TextBlock">
            <Setter Property="FontSize" Value="24"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Foreground" Value="#cdd6f4"/>
            <Setter Property="HorizontalAlignment" Value="Center"/>
            <Setter Property="Margin" Value="0,0,0,20"/>
        </Style>

        <Style x:Key="GameItemStyle" TargetType="Border">
            <Setter Property="Background" Value="#313244"/>
            <Setter Property="CornerRadius" Value="8"/>
            <Setter Property="Margin" Value="5"/>
            <Setter Property="Padding" Value="15,10"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="BorderBrush" Value="#45475a"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Background" Value="#45475a"/>
                    <Setter Property="BorderBrush" Value="#89b4fa"/>
                </Trigger>
            </Style.Triggers>
        </Style>

        <Style x:Key="GameTextStyle" TargetType="TextBlock">
            <Setter Property="Foreground" Value="#cdd6f4"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="TextWrapping" Value="Wrap"/>
            <Setter Property="MaxWidth" Value="180"/>
        </Style>

        <Style x:Key="StatusIndicatorStyle" TargetType="Ellipse">
            <Setter Property="Width" Value="8"/>
            <Setter Property="Height" Value="8"/>
            <Setter Property="HorizontalAlignment" Value="Right"/>
            <Setter Property="VerticalAlignment" Value="Center"/>
            <Setter Property="Margin" Value="5,0"/>
        </Style>

        <Style x:Key="SearchTextBoxStyle" TargetType="TextBox">
            <Setter Property="Background" Value="#313244"/>
            <Setter Property="Foreground" Value="#cdd6f4"/>
            <Setter Property="BorderBrush" Value="#45475a"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="8,4"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="Margin" Value="0,0,0,15"/>
            <Style.Triggers>
                <Trigger Property="IsFocused" Value="True">
                    <Setter Property="BorderBrush" Value="#89b4fa"/>
                </Trigger>
            </Style.Triggers>
        </Style>
    </Window.Resources>

    <Grid Margin="20">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <!-- Title -->
        <TextBlock x:Name="TitleTextBlock"
                   Grid.Row="0"
                   Text="Steam Update Manager"
                   FontSize="32"
                   FontWeight="Bold"
                   Foreground="#89b4fa"
                   HorizontalAlignment="Center"
                   Margin="0,0,0,30"/>

        <!-- Main Content -->
        <Grid Grid.Row="1">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>

            <!-- Updates Enabled Column -->
            <StackPanel Grid.Column="0">
                <TextBlock Text="Updates Enabled" Style="{StaticResource ColumnHeaderStyle}"/>
                <TextBox x:Name="EnabledSearchBox" Style="{StaticResource SearchTextBoxStyle}" Text="Search games..."/>
                <Border Background="#1e1e2e" CornerRadius="10" BorderBrush="#45475a" BorderThickness="2">
                    <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" MaxHeight="500">
                        <StackPanel x:Name="EnabledList" Margin="10"/>
                    </ScrollViewer>
                </Border>
            </StackPanel>

            <!-- Center Arrow -->
            <StackPanel Grid.Column="1" VerticalAlignment="Center" Margin="20,0">
                <TextBlock Text="&lt;-&gt;" FontSize="48" Foreground="#6c7086" HorizontalAlignment="Center"/>
            </StackPanel>

            <!-- Updates Disabled Column -->
            <StackPanel Grid.Column="2">
                <TextBlock Text="Updates Disabled" Style="{StaticResource ColumnHeaderStyle}"/>
                <TextBox x:Name="DisabledSearchBox" Style="{StaticResource SearchTextBoxStyle}" Text="Search games..."/>
                <Border Background="#1e1e2e" CornerRadius="10" BorderBrush="#45475a" BorderThickness="2">
                    <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" MaxHeight="500">
                        <StackPanel x:Name="DisabledList" Margin="10"/>
                    </ScrollViewer>
                </Border>
            </StackPanel>
        </Grid>

        <!-- Status Bar -->
        <Border Grid.Row="2" Background="#181825" CornerRadius="5" Margin="0,20,0,0" Padding="15,10">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>

                <TextBlock x:Name="StatusText"
                          Text="Ready - Click on games to toggle their update status"
                          Foreground="#cdd6f4"
                          VerticalAlignment="Center"/>

                <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                    <TextBlock Text="Total Games: " Foreground="#6c7086"/>
                    <TextBlock x:Name="TotalGamesText" Text="0" Foreground="#89b4fa" FontWeight="SemiBold"/>
                    <TextBlock Text=" | Disabled: " Foreground="#6c7086" Margin="10,0,0,0"/>
                    <TextBlock x:Name="DisabledGamesText" Text="0" Foreground="#f38ba8" FontWeight="SemiBold"/>
                </StackPanel>

                <Button x:Name="HelpButton"
                       Grid.Column="2"
                       Content="?"
                       Width="25"
                       Height="25"
                       Margin="15,0,0,0"
                       Background="#45475a"
                       Foreground="#cdd6f4"
                       BorderBrush="#89b4fa"
                       BorderThickness="1"
                       FontSize="14"
                       FontWeight="Bold"
                       HorizontalAlignment="Right"
                       VerticalAlignment="Center"
                       ToolTipService.InitialShowDelay="0"
                       ToolTipService.ShowDuration="90000">
                    <Button.ToolTip>
                        <ToolTip Content="Steam Update Manager&#x0a;&#x0a;This tool helps you control automatic updates for your Steam games.&#x0a;&#x0a;Click games on the LEFT to DISABLE updates (games won't auto-update)&#x0a;Click games on the RIGHT to ENABLE updates (games will auto-update)&#x0a;&#x0a;The tool works by setting game manifest files to read-only, this prevents&#x0a;steam from being able to modify them for an update thus causing all&#x0a;updates for the game to fail to install.&#x0a;&#x0a;Made by Spark_NV"
                                MaxWidth="400"/>
                    </Button.ToolTip>
                </Button>
            </Grid>
        </Border>

        <!-- Help Text -->
        <TextBlock Grid.Row="3"
                  Text="To disable any game just click your selected games in the left list to disable updates, click games on the right list to re-enable updates for them"
                  Foreground="#6c7086"
                  FontSize="11"
                  HorizontalAlignment="Center"
                  Margin="0,10,0,0"/>
    </Grid>
</Window>
"@

try {
    $Window = [Windows.Markup.XamlReader]::Parse($XAML)

    $Window.Title = "Steam Update Manager v$ScriptVersion"

    $TitleTextBlock = $Window.FindName("TitleTextBlock")
    if ($TitleTextBlock) {
        $TitleTextBlock.Text = "Steam Update Manager v$ScriptVersion"
    }

    $EnabledList = $Window.FindName("EnabledList")
    $DisabledList = $Window.FindName("DisabledList")
    $EnabledSearchBox = $Window.FindName("EnabledSearchBox")
    $DisabledSearchBox = $Window.FindName("DisabledSearchBox")
    $StatusText = $Window.FindName("StatusText")
    $TotalGamesText = $Window.FindName("TotalGamesText")
    $DisabledGamesText = $Window.FindName("DisabledGamesText")

    $EnabledSearchBox.Add_GotFocus({ SearchBox_GotFocus -searchBox $EnabledSearchBox -e $args[1] })
    $EnabledSearchBox.Add_LostFocus({ SearchBox_LostFocus -searchBox $EnabledSearchBox -e $args[1] })
    $EnabledSearchBox.Add_TextChanged({ EnabledSearchBox_TextChanged -searchBox $EnabledSearchBox -e $args[1] })

    $DisabledSearchBox.Add_GotFocus({ SearchBox_GotFocus -searchBox $DisabledSearchBox -e $args[1] })
    $DisabledSearchBox.Add_LostFocus({ SearchBox_LostFocus -searchBox $DisabledSearchBox -e $args[1] })
    $DisabledSearchBox.Add_TextChanged({ DisabledSearchBox_TextChanged -searchBox $DisabledSearchBox -e $args[1] })

    if ($null -eq $EnabledList -or $null -eq $DisabledList) {
        throw "Failed to find required UI elements. EnabledList or DisabledList is null."
    }
    if ($null -eq $StatusText -or $null -eq $TotalGamesText -or $null -eq $DisabledGamesText) {
        throw "Failed to find required UI elements. StatusText, TotalGamesText, or DisabledGamesText is null."
    }

    function New-GameItem {
        param(
            [PSCustomObject]$Game,
            [bool]$IsDisabled,
            [System.Windows.Window]$Window
        )

        $border = New-Object System.Windows.Controls.Border
        $border.Background = [System.Windows.Media.Brushes]::Transparent
        $border.CornerRadius = New-Object System.Windows.CornerRadius 8
        $border.Margin = New-Object System.Windows.Thickness 5
        $border.Padding = New-Object System.Windows.Thickness 15,10,15,10
        $border.BorderThickness = New-Object System.Windows.Thickness 1
        $border.BorderBrush = [System.Windows.Media.Brushes]::Gray
        $border.Cursor = [System.Windows.Input.Cursors]::Hand

        $border.Add_MouseEnter({
            $this.Background = [System.Windows.Media.Brushes]::Gray
            $this.BorderBrush = [System.Windows.Media.Brushes]::LightBlue
        })
        $border.Add_MouseLeave({
            $this.Background = [System.Windows.Media.Brushes]::Transparent
            $this.BorderBrush = [System.Windows.Media.Brushes]::Gray
        })

        $grid = New-Object System.Windows.Controls.Grid
        $col1 = New-Object System.Windows.Controls.ColumnDefinition
        $col1.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star)
        $col2 = New-Object System.Windows.Controls.ColumnDefinition
        $col2.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Auto)
        [void]$grid.ColumnDefinitions.Add($col1)
        [void]$grid.ColumnDefinitions.Add($col2)

        $textBlock = New-Object System.Windows.Controls.TextBlock
        $textBlock.Text = $Game.Name
        $textBlock.ToolTip = "$($Game.Name) (AppID: $($Game.AppId))"
        $textBlock.Foreground = [System.Windows.Media.Brushes]::White
        $textBlock.FontSize = 13
        $textBlock.TextWrapping = [System.Windows.TextWrapping]::Wrap
        $textBlock.MaxWidth = 180
        [System.Windows.Controls.Grid]::SetColumn($textBlock, 0)

        $statusIndicator = New-Object System.Windows.Shapes.Ellipse
        $statusIndicator.Width = 8
        $statusIndicator.Height = 8
        $statusIndicator.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right
        $statusIndicator.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
        $statusIndicator.Margin = New-Object System.Windows.Thickness 5,0,0,0
        if ($IsDisabled) {
            $statusIndicator.Fill = [System.Windows.Media.Brushes]::Red
        } else {
            $statusIndicator.Fill = [System.Windows.Media.Brushes]::Green
        }
        [System.Windows.Controls.Grid]::SetColumn($statusIndicator, 1)

        [void]$grid.Children.Add($textBlock)
        [void]$grid.Children.Add($statusIndicator)
        $border.Child = $grid

        $border.Tag = $Game

        $border.Add_MouseLeftButtonUp({
            param($senderControl, $e)
            $game = $senderControl.Tag
            Set-GameUpdateStatus -Game $game -Border $senderControl
        })

        return $border
    }

    function Move-GameItem {
        param(
            [System.Windows.Controls.Border]$Item,
            [System.Windows.Controls.StackPanel]$FromList,
            [System.Windows.Controls.StackPanel]$ToList,
            [bool]$ToDisabled
        )

        if ($null -ne $FromList -and $null -ne $FromList.Children) {
            [void]$FromList.Children.Remove($Item)
        }

        $grid = $Item.Child
        $indicator = $grid.Children[1]
        if ($ToDisabled) {
            $indicator.Fill = [System.Windows.Media.Brushes]::Red
        } else {
            $indicator.Fill = [System.Windows.Media.Brushes]::Green
        }

        if ($null -ne $ToList -and $null -ne $ToList.Children) {
            [void]$ToList.Children.Add($Item)
        }

        $Item.Opacity = 0
        $animation = New-Object System.Windows.Media.Animation.DoubleAnimation 0, 1, (New-Object System.Windows.Duration ([System.TimeSpan]::FromMilliseconds(300)))
        $Item.BeginAnimation([System.Windows.Controls.Border]::OpacityProperty, $animation)
    }

    function Set-GameUpdateStatus {
        param(
            [PSCustomObject]$Game,
            [System.Windows.Controls.Border]$Border
        )

        try {
            $action = if ($Game.IsUpdateDisabled) { "Enabling" } else { "Disabling" }
            $manifestFileName = Split-Path $Game.ManifestPath -Leaf
            Write-Log "$action updates for game: $($Game.Name) (AppID: $($Game.AppId) -- $manifestFileName)"

            $newStatus = !$Game.IsUpdateDisabled

            if (Set-UpdateStatus -ManifestPath $Game.ManifestPath -DisableUpdates $newStatus) {
                $Game.IsUpdateDisabled = $newStatus

                if ($newStatus) {
                    Move-GameItem -Item $Border -FromList $EnabledList -ToList $DisabledList -ToDisabled $true
                } else {
                    Move-GameItem -Item $Border -FromList $DisabledList -ToList $EnabledList -ToDisabled $false
                }

                Update-StatusDisplay
                if ($newStatus) {
                    $StatusText.Text = "Successfully disabled updates for $($Game.Name)"
                } else {
                    $StatusText.Text = "Successfully enabled updates for $($Game.Name)"
                }
            } else {
                Write-Log "Failed to update manifest for $($Game.Name)" -Level "ERROR"
                $StatusText.Text = "Failed to update status for $($Game.Name)"
            }
        }
        catch {
            Write-Log "Error toggling update status for $($Game.Name): $($_.Exception.Message)" -Level "ERROR"
            $StatusText.Text = "Error toggling update status: $($_.Exception.Message)"
        }
    }
    function Update-StatusDisplay {
        if ($null -eq $EnabledList -or $null -eq $DisabledList -or $null -eq $TotalGamesText -or $null -eq $DisabledGamesText) {
            return
        }
        $totalGames = $EnabledList.Children.Count + $DisabledList.Children.Count
        $disabledGames = $DisabledList.Children.Count

        $TotalGamesText.Text = $totalGames.ToString()
        $DisabledGamesText.Text = $disabledGames.ToString()
    }
    function Search-GamesList {
        param(
            [System.Windows.Controls.StackPanel]$GamesList,
            [string]$SearchText
        )

        if ($null -eq $GamesList) {
            return
        }

        foreach ($child in $GamesList.Children) {
            if ($child -is [System.Windows.Controls.Border]) {
                $gameName = $child.Tag.Name
                if ($SearchText -and $gameName -notlike "*$SearchText*") {
                    $child.Visibility = [System.Windows.Visibility]::Collapsed
                } else {
                    $child.Visibility = [System.Windows.Visibility]::Visible
                }
            }
        }
    }
    function SearchBox_GotFocus {
        param($searchBox, $e)
        if ($searchBox.Text -eq "Search games...") {
            $searchBox.Text = ""
            $searchBox.Foreground = [System.Windows.Media.Brushes]::White
        }
    }

    function SearchBox_LostFocus {
        param($searchBox, $e)
        if ([string]::IsNullOrWhiteSpace($searchBox.Text)) {
            $searchBox.Text = "Search games..."
            $searchBox.Foreground = [System.Windows.Media.Brushes]::Gray
        }
    }
    function EnabledSearchBox_TextChanged {
        param($searchBox, $e)
        $searchText = $searchBox.Text
        if ($searchText -eq "Search games...") {
            $searchText = ""
        }
        Search-GamesList -GamesList $EnabledList -SearchText $searchText
    }

    function DisabledSearchBox_TextChanged {
        param($searchBox, $e)
        $searchText = $searchBox.Text
        if ($searchText -eq "Search games...") {
            $searchText = ""
        }
        Search-GamesList -GamesList $DisabledList -SearchText $searchText
    }
    function Import-SteamApps {
        try {
            $StatusText.Text = "Finding Steam installation..."
            $steamPath = Get-SteamInstallPath

            $StatusText.Text = "Scanning Steam libraries..."
            $libraryPaths = Get-SteamLibraryPaths -SteamPath $steamPath

            $StatusText.Text = "Loading game manifests..."
            $apps = Get-SteamApps -LibraryPaths $libraryPaths

            $enabledCount = 0
            $disabledCount = 0

            foreach ($app in $apps) {
                $gameItem = New-GameItem -Game $app -IsDisabled $app.IsUpdateDisabled -Window $Window

                if ($null -eq $gameItem) {
                    Write-Log "Failed to create GUI element for game: $($app.Name)" -Level "WARN"
                    continue
                }

                if ($app.IsUpdateDisabled) {
                    if ($null -ne $DisabledList -and $null -ne $DisabledList.Children) {
                        [void]$DisabledList.Children.Add($gameItem)
                        $disabledCount++
                    }
                } else {
                    if ($null -ne $EnabledList -and $null -ne $EnabledList.Children) {
                        [void]$EnabledList.Children.Add($gameItem)
                        $enabledCount++
                    }
                }
            }

            Update-StatusDisplay
            $StatusText.Text = "Loaded $($apps.Count) games ($enabledCount enabled, $disabledCount disabled)"
            Write-Log "initialization complete: $enabledCount games with updates enabled, $disabledCount games with updates disabled"
        }
        catch {
            Write-Log "Critical error during Steam app import: $($_.Exception.Message)" -Level "ERROR"
            $StatusText.Text = "Error: $($_.Exception.Message)"
            [System.Windows.MessageBox]::Show("Error loading Steam apps: $($_.Exception.Message)", "Steam Update Manager", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
        }
    }

    $Window.Add_Loaded({
        Import-SteamApps

        if ($EnabledSearchBox) {
            $EnabledSearchBox.Foreground = [System.Windows.Media.Brushes]::Gray
        }
        if ($DisabledSearchBox) {
            $DisabledSearchBox.Foreground = [System.Windows.Media.Brushes]::Gray
        }
    })

    $Window.ShowDialog()

}
catch {
    Write-Log "Critical application error: $($_.Exception.Message)" -Level "ERROR"
    [System.Windows.MessageBox]::Show("Critical error: $($_.Exception.Message)", "Steam Update Manager", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
}
