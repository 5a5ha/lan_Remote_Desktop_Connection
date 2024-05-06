# Prompt user for credentials
$credentials = Get-Credential -Message "Enter Admin Credentials"

# Prompt user for IP address and validate it
do {
    $ipAddress = Read-Host "Enter the IP address of the remote computer"
    $ipIsValid = [System.Net.IPAddress]::TryParse($ipAddress, [ref]$null)
    if (-not $ipIsValid) {
        Write-Host "Invalid IP address. Please enter a valid IP address." -ForegroundColor Red
    }
} until ($ipIsValid)

# Allow remote management - Enable PSRemoting
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

# Check connectivity to remote IP address
if (Test-Connection -ComputerName $ipAddress -Count 1 -Quiet) {
    Write-Host "Test connection to $ipAddress successful." -ForegroundColor Green
} else {
    Write-Host "Unable to connect to $ipAddress. Please check network connectivity and try again." -ForegroundColor Red
    exit
}

# Get remote computer name
$remoteComputerName = Invoke-Command -ComputerName $ipAddress -Credential $credentials -ScriptBlock {hostname}
if (!$remoteComputerName) {
    Write-Host "Unable to get remote computer name." -ForegroundColor Red
    exit 
} else { 
    Write-Host "The computer name is $remoteComputerName." -ForegroundColor Green
}

# Get active user session on remote computer
$session = Invoke-Command -ComputerName $ipAddress -Credential $credentials -ScriptBlock { qwinsta | findstr "Active" }
if (!$session) {
    Write-Host "There is no Active user." -ForegroundColor Red
    exit
} else {
    $userSessionID = $session -replace '\D'
    Write-Host "Found active user $session." -ForegroundColor Green
}
# Make necessary changes on remote computer for remote connection
# Allow remote connection
Invoke-Command -ComputerName $ipAddress -Credential $credentials -ScriptBlock {echo Y | reg add "HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Terminal Server" /v fDenyTSConnections /t REG_DWORD /d 0 /f} -ErrorAction SilentlyContinue
# Allow shadowing remote computer
Invoke-Command -ComputerName $ipAddress -Credential $credentials -ScriptBlock {echo Y | reg add "HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services" /v Shadow /t REG_DWORD /d 2} -ErrorAction SilentlyContinue
# Configure firewall rules to allow remote desktop connections
Invoke-Command -ComputerName $ipAddress -Credential $credentials -ScriptBlock {echo Y | netsh advfirewall firewall set rule group="remote desktop" new enable=Yes} -ErrorAction SilentlyContinue

# Make a connection to the remote computer
mstsc /shadow:$userSessionID /v:$ipAddress /noconsentprompt /control

# Active remote connection check up
do {
    $endSession = netstat -ano | findstr $ipAddress
    Write-Host "Active remote session..." -ForegroundColor Green
    sleep 2
   }
while ($endSession)    
# Return to initial configuration
if (!$endSession)
{
    $message = "`nRemote session has ended`n"
    Write-Host $message -ForegroundColor Red
    # Deny remote connection
    Invoke-Command -ComputerName $ipAddress -Credential $credentials -ScriptBlock {echo Y | reg add "HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Terminal Server" /v fDenyTSConnections /t REG_DWORD /d 1 /f} -ErrorAction SilentlyContinue
    # Deny shadowing remote computer
    Invoke-Command -ComputerName $ipAddress -Credential $credentials -ScriptBlock {echo Y | reg add "HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services" /v Shadow /t REG_DWORD /d 0} -ErrorAction SilentlyContinue
    # Deny firewall remote desktop connections
    Invoke-Command -ComputerName $ipAddress -Credential $credentials -ScriptBlock {echo Y | netsh advfirewall firewall set rule group="remote desktop" new enable=No} -ErrorAction SilentlyContinue
    # Deny remote management - Disable PSRemoting
    Invoke-Command -ComputerName $ipAddress -Credential $credentials -ScriptBlock {Start-Process powershell -ArgumentList 'Disable-PSRemoting -Force'} -ErrorAction SilentlyContinue
    sleep 2
    exit
}



