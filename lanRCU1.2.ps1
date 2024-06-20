# Step 0: Nullify all methods, arguments, and variables
Get-CimSession | Remove-CimSession
Remove-Variable -Name ipAddress, ipIsValid, SessionArgs, MethodArgs, results, remoteCommands, remoteConfigScript, remoteCleanupScript, credentials, remoteInfo, mstscArgs, remoteSessionActive -ErrorAction SilentlyContinue

# Step 1: Prompt user for credentials and IP address
$credentials = Get-Credential -Message "Enter Admin Credentials"

do {
    $ipAddress = Read-Host "Enter the IP address of the remote computer"
    $ipIsValid = [System.Net.IPAddress]::TryParse($ipAddress, [ref]$null)
    if (-not $ipIsValid) {
        Write-Host "Invalid IP address. Please enter a valid IP address." -ForegroundColor Red
    }
} until ($ipIsValid)

# Step 2: Check connectivity to remote IP address
try {
    if (Test-Connection -ComputerName $ipAddress -Count 1 -Quiet) {
        Write-Host "Test connectivity to $ipAddress successful." -ForegroundColor Green
    } else {
        Write-Host "Unable to connect to $ipAddress. Please check network connectivity and try again." -ForegroundColor Red
        exit
    }
} catch {
    Write-Host "Error during connectivity check: $_" -ForegroundColor Red
    exit
}

# Step 3: Enable remote management and shadowing on the remote computer
try {
    $SessionArgs = @{
        ComputerName  = $ipAddress
        Credential    = $credentials
        SessionOption = New-CimSessionOption -Protocol Dcom
    }
    $MethodArgs = @{
        ClassName     = 'Win32_Process'
        MethodName    = 'Create'
        CimSession    = New-CimSession @SessionArgs
        Arguments     = @{
            CommandLine = "powershell Start-Process powershell -ArgumentList 'Enable-PSRemoting -Force'"
        }
    }
    Invoke-CimMethod @MethodArgs
    Write-Host "PSRemoting enabled successfully on $ipAddress." -ForegroundColor Green
} catch {
    Write-Host "Failed to enable PSRemoting on ${ipAddress}: $_" -ForegroundColor Red
    exit
}

# Step 4: Configure remote settings
$remoteConfigScript = {
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services" -Name "fDenyTSConnections" -Value 0
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services" -Name "Shadow" -Value 2
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server" -Name "fDenyTSConnections" -Value 0
    netsh advfirewall firewall set rule group="remote desktop" new enable=Yes
}

try {
    Invoke-Command -ComputerName $ipAddress -Credential $credentials -ScriptBlock $remoteConfigScript
    Write-Host "Remote settings configured successfully on $ipAddress." -ForegroundColor Green
} catch {
    Write-Host "Failed to configure remote settings on ${ipAddress}: $_" -ForegroundColor Red
    exit
}

# Step 5: Get remote computer details and attempt shadowing
$remoteCommands = {
    # Get remote computer name
    $remoteComputerName = hostname

    # Get active user session
    $session = qwinsta | Select-String -Pattern "Active"
    if ($session) {
        $sessionDetails = $session -split '\s+'
        $userSessionID = $sessionDetails[3]
        $userName = $sessionDetails[2]
    } else {
        $userSessionID = $null
        $userName = $null
    }

    # Return results
    return @{
        ComputerName = $remoteComputerName
        UserSessionID = $userSessionID
        UserName = $userName
    }
}

try {
    $remoteInfo = Invoke-Command -ComputerName $ipAddress -Credential $credentials -ScriptBlock $remoteCommands
    Write-Host "Remote computer name: $($remoteInfo.ComputerName)" -ForegroundColor Green
    Start-Sleep -Seconds 1
    Write-Host "Active user session ID: $($remoteInfo.UserSessionID)" -ForegroundColor Green
    Start-Sleep -Seconds 1
    Write-Host "Active user name: $($remoteInfo.UserName)" -ForegroundColor Green
    Start-Sleep -Seconds 1

    if (-not $remoteInfo.UserSessionID) {
        Write-Host "No active user session found on remote computer." -ForegroundColor Red
        exit
    }

    $mstscArgs = "/shadow:$($remoteInfo.UserSessionID) /v:$ipAddress /noconsentprompt /control"
    $mstscProcess = Start-Process "mstsc.exe" -ArgumentList $mstscArgs -NoNewWindow -PassThru
    Write-Host "Remote Desktop shadowing command executed: mstsc.exe $mstscArgs" -ForegroundColor Yellow
} catch {
    Write-Host "Failed to get remote computer details or start shadowing: $_" -ForegroundColor Red
    exit
}

# Step 6: Monitor the session and cleanup
Write-Host "Waiting for the remote session to end." -ForegroundColor Yellow

try {
    while (!$mstscProcess.HasExited) {
        Write-Host "Remote Desktop Session is Active..." -ForegroundColor Green
        Start-Sleep -Seconds 2
    }
    Write-Host "Remote Desktop session closed." -ForegroundColor Red
} catch {
    Write-Host "Error while monitoring the session: $_" -ForegroundColor Red
}

$remoteCleanupScript = {
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server" -Name "fDenyTSConnections" -Value 1
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services" -Name "Shadow" -Value 0
    Get-NetFirewallRule -DisplayName "Allow RDP" | Remove-NetFirewallRule
    Start-Process powershell -ArgumentList 'Disable-PSRemoting -Force'
}

try {
    Invoke-Command -ComputerName $ipAddress -Credential $credentials -ScriptBlock $remoteCleanupScript -ErrorAction SilentlyContinue
    Write-Host "Cleanup commands executed successfully on $ipAddress." -ForegroundColor Green
} catch {
    Write-Host "Failed to execute cleanup commands on ${ipAddress}: $_" -ForegroundColor Red
    exit
}

Start-Sleep -Seconds 2
exit
