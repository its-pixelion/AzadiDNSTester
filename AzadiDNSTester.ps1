# ==============================================================================
# Azadi DNS Tester - PowerShell Edition (No Dependencies)
# ==============================================================================
# Tests DNS servers from dns_servers.txt and saves working ones to working_dns.txt
# Supports ANY input format - extracts ALL IPv4 addresses automatically
# No external dependencies - uses only built-in cmdlets
# Supports PowerShell 5.1+ (uses runspaces) and PowerShell 7+ (uses -Parallel)
# ==============================================================================

param(
    [string]$InputFile = "",
    [string]$OutputFile = "",
    [switch]$NonInteractive,
    [int]$Workers = 0,
    [int]$Timeout = 0,
    [string]$Domain = ""
)

# Get script directory
$ScriptDir = $PSScriptRoot
if (-not $ScriptDir) { $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $ScriptDir) { $ScriptDir = Get-Location }

# Set default file paths
if (-not $InputFile) { $InputFile = Join-Path $ScriptDir "dns_servers.txt" }
if (-not $OutputFile) { $OutputFile = Join-Path $ScriptDir "working_dns.txt" }

# Defaults
$DEFAULT_WORKERS = 100
$DEFAULT_TIMEOUT = 3
$DEFAULT_DOMAIN = "google.com"

# Thread-safe collections
$script:WorkingServers = [System.Collections.Concurrent.ConcurrentBag[PSObject]]::new()
$script:FileLock = [System.Object]::new()

# ==============================================================================
# Utility Functions
# ==============================================================================

function Write-ColorOutput {
    param(
        [string]$Message,
        [string]$Color = "White"
    )
    Write-Host $Message -ForegroundColor $Color
}

function Get-IPv4Addresses {
    param([string]$FilePath)
    
    if (-not (Test-Path $FilePath)) {
        return @()
    }
    
    $content = Get-Content $FilePath -Raw
    $ipPattern = '\b(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\b'
    
    $matches = [regex]::Matches($content, $ipPattern)
    $allIps = $matches | ForEach-Object { $_.Value }
    $uniqueIps = $allIps | Select-Object -Unique
    
    return @{
        UniqueIPs = @($uniqueIps)
        TotalCount = $allIps.Count
        UniqueCount = $uniqueIps.Count
    }
}

function New-SampleFile {
    param([string]$FilePath)
    
    $sampleServers = @(
        "1.1.1.1",
        "1.0.0.1",
        "8.8.8.8",
        "8.8.4.4",
        "9.9.9.9",
        "208.67.222.222",
        "208.67.220.220",
        "4.2.2.1",
        "4.2.2.2"
    )
    
    $sampleServers | Out-File -FilePath $FilePath -Encoding UTF8
    Write-ColorOutput "Created sample $FilePath with $($sampleServers.Count) servers" -Color Cyan
}

function Write-OutputHeader {
    param(
        [string]$FilePath,
        [string]$Domain
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $header = @(
        "# Working DNS servers - Tested: $timestamp",
        "# Test domain: $Domain",
        "# Format: IP (response_time_ms)"
    )
    
    $header | Out-File -FilePath $FilePath -Encoding UTF8
}

function Save-WorkingServer {
    param(
        [string]$FilePath,
        [string]$Server,
        [int]$ResponseTime
    )
    
    $line = "$Server (${ResponseTime}ms)"
    
    # Thread-safe append
    [System.Threading.Monitor]::Enter($script:FileLock)
    try {
        Add-Content -Path $FilePath -Value $line -Encoding UTF8
    }
    finally {
        [System.Threading.Monitor]::Exit($script:FileLock)
    }
}

# ==============================================================================
# DNS Testing Functions
# ==============================================================================

function Test-DnsServer {
    param(
        [string]$Server,
        [string]$Domain,
        [int]$TimeoutSeconds
    )
    
    $result = @{
        Server = $Server
        Success = $false
        ResponseTime = 0
        ResolvedIP = $null
        Error = $null
    }
    
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    
    try {
        # Try Resolve-DnsName first (Windows 8+ / Server 2012+)
        if (Get-Command Resolve-DnsName -ErrorAction SilentlyContinue) {
            $dnsResult = Resolve-DnsName -Name $Domain -Server $Server -Type A -DnsOnly -ErrorAction Stop
            $stopwatch.Stop()
            
            $aRecords = $dnsResult | Where-Object { $_.Type -eq 'A' }
            if ($aRecords) {
                $result.Success = $true
                $result.ResolvedIP = $aRecords[0].IPAddress
                $result.ResponseTime = [math]::Round($stopwatch.ElapsedMilliseconds)
            }
        }
        else {
            # Fallback to .NET DNS (less control over server)
            # Note: This doesn't allow specifying a custom DNS server easily
            # We'll use nslookup via process
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = "nslookup"
            $psi.Arguments = "$Domain $Server"
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            
            $process = New-Object System.Diagnostics.Process
            $process.StartInfo = $psi
            $process.Start() | Out-Null
            
            $completed = $process.WaitForExit($TimeoutSeconds * 1000)
            $stopwatch.Stop()
            
            if ($completed -and $process.ExitCode -eq 0) {
                $output = $process.StandardOutput.ReadToEnd()
                
                # Parse nslookup output for IP address
                if ($output -match 'Address:\s*(\d+\.\d+\.\d+\.\d+)') {
                    # Skip the first Address line (server's address)
                    $addresses = [regex]::Matches($output, 'Address:\s*(\d+\.\d+\.\d+\.\d+)')
                    if ($addresses.Count -gt 1) {
                        $result.Success = $true
                        $result.ResolvedIP = $addresses[1].Groups[1].Value
                        $result.ResponseTime = [math]::Round($stopwatch.ElapsedMilliseconds)
                    }
                }
            }
            else {
                if (-not $completed) {
                    $process.Kill()
                    $result.Error = "Timeout"
                }
            }
        }
    }
    catch [System.Management.Automation.CommandNotFoundException] {
        $result.Error = "No DNS tool available"
    }
    catch {
        $stopwatch.Stop()
        $result.ResponseTime = [math]::Round($stopwatch.ElapsedMilliseconds)
        $result.Error = $_.Exception.Message
        if ($result.Error.Length -gt 30) {
            $result.Error = $result.Error.Substring(0, 30) + "..."
        }
    }
    
    return $result
}

# ==============================================================================
# User Input Functions
# ==============================================================================

function Get-WorkerCount {
    Write-Host ""
    Write-Host "Workers (parallel tests, default: $DEFAULT_WORKERS, max: 500):"
    Write-Host "  Enter number (1-500) or press Enter for $DEFAULT_WORKERS"
    $choice = Read-Host "Workers"
    
    if ([string]::IsNullOrWhiteSpace($choice)) {
        return $DEFAULT_WORKERS
    }
    
    $num = 0
    if ([int]::TryParse($choice, [ref]$num) -and $num -ge 1 -and $num -le 500) {
        return $num
    }
    
    Write-ColorOutput "Invalid! Using default: $DEFAULT_WORKERS" -Color Yellow
    return $DEFAULT_WORKERS
}

function Get-TimeoutValue {
    Write-Host ""
    Write-Host "Timeout per test (seconds, default: $DEFAULT_TIMEOUT, range: 1-10):"
    Write-Host "  Enter number (1-10) or press Enter for $DEFAULT_TIMEOUT"
    $choice = Read-Host "Timeout"
    
    if ([string]::IsNullOrWhiteSpace($choice)) {
        return $DEFAULT_TIMEOUT
    }
    
    $num = 0
    if ([int]::TryParse($choice, [ref]$num) -and $num -ge 1 -and $num -le 10) {
        return $num
    }
    
    Write-ColorOutput "Invalid! Using default: $DEFAULT_TIMEOUT" -Color Yellow
    return $DEFAULT_TIMEOUT
}

function Get-TestDomain {
    $domains = @("google.com", "cloudflare.com", "example.com")
    
    Write-Host ""
    Write-Host "Test domains (enter number 1-3 or type domain):"
    Write-Host "  1. google.com"
    Write-Host "  2. cloudflare.com"
    Write-Host "  3. example.com"
    Write-Host "  or type your own domain"
    $choice = Read-Host "Enter choice (1-3 or domain)"
    
    if ([string]::IsNullOrWhiteSpace($choice)) {
        return "google.com"
    }
    
    switch ($choice) {
        "1" { return "google.com" }
        "2" { return "cloudflare.com" }
        "3" { return "example.com" }
        default {
            if ($choice -match '\.' -and $choice -notmatch '^https?://') {
                return $choice
            }
            Write-ColorOutput "Invalid! Using default: google.com" -Color Yellow
            return "google.com"
        }
    }
}

# ==============================================================================
# Parallel Execution Functions
# ==============================================================================

function Invoke-ParallelDnsTest-PS7 {
    param(
        [string[]]$Servers,
        [string]$Domain,
        [int]$TimeoutSeconds,
        [int]$Workers,
        [string]$OutputFilePath
    )
    
    $completed = 0
    $total = $Servers.Count
    $results = [System.Collections.Concurrent.ConcurrentBag[PSObject]]::new()
    $fileLock = [System.Object]::new()
    
    $Servers | ForEach-Object -Parallel {
        $server = $_
        $domain = $using:Domain
        $timeout = $using:TimeoutSeconds
        $outputFile = $using:OutputFilePath
        $results = $using:results
        $lock = $using:fileLock
        
        $result = @{
            Server = $server
            Success = $false
            ResponseTime = 0
            ResolvedIP = $null
            Error = $null
        }
        
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        
        try {
            $dnsResult = Resolve-DnsName -Name $domain -Server $server -Type A -DnsOnly -ErrorAction Stop
            $stopwatch.Stop()
            
            $aRecords = $dnsResult | Where-Object { $_.Type -eq 'A' }
            if ($aRecords) {
                $result.Success = $true
                $result.ResolvedIP = $aRecords[0].IPAddress
                $result.ResponseTime = [math]::Round($stopwatch.ElapsedMilliseconds)
                
                # Save immediately
                $line = "$server ($($result.ResponseTime)ms)"
                [System.Threading.Monitor]::Enter($lock)
                try {
                    Add-Content -Path $outputFile -Value $line -Encoding UTF8
                }
                finally {
                    [System.Threading.Monitor]::Exit($lock)
                }
            }
        }
        catch {
            $stopwatch.Stop()
            $result.ResponseTime = [math]::Round($stopwatch.ElapsedMilliseconds)
            $errMsg = $_.Exception.Message
            if ($errMsg.Length -gt 30) { $errMsg = $errMsg.Substring(0, 30) + "..." }
            $result.Error = $errMsg
        }
        
        $results.Add([PSCustomObject]$result)
        
        # Progress update
        $done = $results.Count
        $pct = [math]::Round(($done / $using:total) * 100, 1)
        Write-Host "`rProgress: $done/$($using:total) ($pct%)" -NoNewline
        
    } -ThrottleLimit $Workers
    
    Write-Host ""  # New line after progress
    return $results.ToArray()
}

function Invoke-ParallelDnsTest-PS5 {
    param(
        [string[]]$Servers,
        [string]$Domain,
        [int]$TimeoutSeconds,
        [int]$Workers,
        [string]$OutputFilePath
    )
    
    # Create runspace pool
    $runspacePool = [runspacefactory]::CreateRunspacePool(1, $Workers)
    $runspacePool.Open()
    
    $jobs = @()
    $results = [System.Collections.Concurrent.ConcurrentBag[PSObject]]::new()
    
    $scriptBlock = {
        param($Server, $Domain, $TimeoutSeconds, $OutputFilePath)
        
        $result = @{
            Server = $Server
            Success = $false
            ResponseTime = 0
            ResolvedIP = $null
            Error = $null
        }
        
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        
        try {
            if (Get-Command Resolve-DnsName -ErrorAction SilentlyContinue) {
                $dnsResult = Resolve-DnsName -Name $Domain -Server $Server -Type A -DnsOnly -ErrorAction Stop
                $stopwatch.Stop()
                
                $aRecords = $dnsResult | Where-Object { $_.Type -eq 'A' }
                if ($aRecords) {
                    $result.Success = $true
                    $result.ResolvedIP = $aRecords[0].IPAddress
                    $result.ResponseTime = [math]::Round($stopwatch.ElapsedMilliseconds)
                    
                    # Save immediately (atomic append)
                    $line = "$Server ($($result.ResponseTime)ms)"
                    [System.IO.File]::AppendAllText($OutputFilePath, "$line`r`n")
                }
            }
            else {
                # Fallback to nslookup
                $psi = New-Object System.Diagnostics.ProcessStartInfo
                $psi.FileName = "nslookup"
                $psi.Arguments = "$Domain $Server"
                $psi.RedirectStandardOutput = $true
                $psi.RedirectStandardError = $true
                $psi.UseShellExecute = $false
                $psi.CreateNoWindow = $true
                
                $process = New-Object System.Diagnostics.Process
                $process.StartInfo = $psi
                $process.Start() | Out-Null
                
                $completed = $process.WaitForExit($TimeoutSeconds * 1000)
                $stopwatch.Stop()
                
                if ($completed -and $process.ExitCode -eq 0) {
                    $output = $process.StandardOutput.ReadToEnd()
                    $addresses = [regex]::Matches($output, 'Address:\s*(\d+\.\d+\.\d+\.\d+)')
                    if ($addresses.Count -gt 1) {
                        $result.Success = $true
                        $result.ResolvedIP = $addresses[1].Groups[1].Value
                        $result.ResponseTime = [math]::Round($stopwatch.ElapsedMilliseconds)
                        
                        $line = "$Server ($($result.ResponseTime)ms)"
                        [System.IO.File]::AppendAllText($OutputFilePath, "$line`r`n")
                    }
                }
                else {
                    if (-not $completed) {
                        $process.Kill()
                        $result.Error = "Timeout"
                    }
                }
            }
        }
        catch {
            $stopwatch.Stop()
            $result.ResponseTime = [math]::Round($stopwatch.ElapsedMilliseconds)
            $errMsg = $_.Exception.Message
            if ($errMsg.Length -gt 30) { $errMsg = $errMsg.Substring(0, 30) + "..." }
            $result.Error = $errMsg
        }
        
        return [PSCustomObject]$result
    }
    
    # Start all jobs
    foreach ($server in $Servers) {
        $powershell = [powershell]::Create().AddScript($scriptBlock)
        $powershell.AddArgument($server)
        $powershell.AddArgument($Domain)
        $powershell.AddArgument($TimeoutSeconds)
        $powershell.AddArgument($OutputFilePath)
        $powershell.RunspacePool = $runspacePool
        
        $jobs += @{
            PowerShell = $powershell
            Handle = $powershell.BeginInvoke()
        }
    }
    
    # Wait for completion with progress
    $total = $jobs.Count
    $allResults = @()
    $completed = 0
    
    while ($jobs.Count -gt 0) {
        $finishedJobs = @()
        
        foreach ($job in $jobs) {
            if ($job.Handle.IsCompleted) {
                $result = $job.PowerShell.EndInvoke($job.Handle)
                $allResults += $result
                $job.PowerShell.Dispose()
                $finishedJobs += $job
                $completed++
                
                $pct = [math]::Round(($completed / $total) * 100, 1)
                Write-Host "`rProgress: $completed/$total ($pct%)" -NoNewline
            }
        }
        
        foreach ($finished in $finishedJobs) {
            $jobs = $jobs | Where-Object { $_ -ne $finished }
        }
        
        if ($jobs.Count -gt 0) {
            Start-Sleep -Milliseconds 100
        }
    }
    
    Write-Host ""  # New line after progress
    $runspacePool.Close()
    $runspacePool.Dispose()
    
    return $allResults
}

# ==============================================================================
# Main Function
# ==============================================================================

function Main {
    Write-Host "Azadi DNS Tester (PowerShell Edition)"
    Write-Host "======================================================================"
    
    # Detect PowerShell version
    $psVersion = $PSVersionTable.PSVersion.Major
    Write-ColorOutput "PowerShell Version: $($PSVersionTable.PSVersion)" -Color Cyan
    
    if ($psVersion -ge 7) {
        Write-ColorOutput "Parallel Mode: ForEach-Object -Parallel (PS7+)" -Color Cyan
    }
    else {
        Write-ColorOutput "Parallel Mode: Runspace Pool (PS5.1 compatible)" -Color Cyan
    }
    
    # Check for Resolve-DnsName
    if (Get-Command Resolve-DnsName -ErrorAction SilentlyContinue) {
        Write-ColorOutput "DNS Tool: Resolve-DnsName" -Color Cyan
    }
    else {
        Write-ColorOutput "DNS Tool: nslookup (fallback)" -Color Yellow
    }
    
    # Load servers
    if (-not (Test-Path $InputFile)) {
        Write-Host "$InputFile not found. Creating sample file..."
        New-SampleFile -FilePath $InputFile
    }
    
    # Extract unique IPs
    $ipData = Get-IPv4Addresses -FilePath $InputFile
    $servers = $ipData.UniqueIPs
    
    if ($servers.Count -eq 0) {
        Write-ColorOutput "No valid IPv4 addresses found in $InputFile" -Color Red
        exit 1
    }
    
    Write-Host "Extracted $($ipData.UniqueCount) UNIQUE IPv4 addresses from $InputFile"
    Write-Host "Total IPs found (with duplicates): $($ipData.TotalCount)"
    Write-Host "UNIQUE IPs: $($ipData.UniqueCount)"
    
    # Get configuration (interactive or from parameters)
    if ($NonInteractive) {
        $workerCount = if ($Workers -gt 0) { $Workers } else { $DEFAULT_WORKERS }
        $timeoutValue = if ($Timeout -gt 0) { $Timeout } else { $DEFAULT_TIMEOUT }
        $testDomain = if ($Domain) { $Domain } else { $DEFAULT_DOMAIN }
    }
    else {
        $workerCount = Get-WorkerCount
        $timeoutValue = Get-TimeoutValue
        $testDomain = Get-TestDomain
    }
    
    # Write header
    Write-OutputHeader -FilePath $OutputFile -Domain $testDomain
    
    Write-Host ""
    Write-Host "Starting test of $($servers.Count) DNS servers"
    Write-Host "Config: Workers=$workerCount | Timeout=${timeoutValue}s | Domain=$testDomain"
    Write-Host "Working servers will be SAVED IMMEDIATELY as found!"
    Write-Host "----------------------------------------------------------------------"
    
    $startTime = Get-Date
    
    Write-Host "Testing servers..."
    
    # Run parallel tests based on PS version
    if ($psVersion -ge 7) {
        $results = Invoke-ParallelDnsTest-PS7 -Servers $servers -Domain $testDomain -TimeoutSeconds $timeoutValue -Workers $workerCount -OutputFilePath $OutputFile
    }
    else {
        $results = Invoke-ParallelDnsTest-PS5 -Servers $servers -Domain $testDomain -TimeoutSeconds $timeoutValue -Workers $workerCount -OutputFilePath $OutputFile
    }
    
    $endTime = Get-Date
    $elapsed = [math]::Round(($endTime - $startTime).TotalSeconds, 1)
    
    # Process results
    $working = @($results | Where-Object { $_.Success })
    $failed = @($results | Where-Object { -not $_.Success })
    
    # Display individual results
    foreach ($result in $results) {
        if ($result.Success) {
            Write-ColorOutput "✅ $($result.Server) OK $($result.ResponseTime)ms ($($result.ResolvedIP))" -Color Green
        }
        else {
            $errInfo = if ($result.Error) { $result.Error } else { "timeout/error" }
            Write-ColorOutput "❌ $($result.Server) FAIL ($errInfo)" -Color Red
        }
    }
    
    # Calculate statistics
    $successRate = if ($servers.Count -gt 0) { [math]::Round(($working.Count / $servers.Count) * 100, 1) } else { 0 }
    
    # Print summary
    Write-Host ""
    Write-Host "======================================================================"
    Write-Host "DNS SERVER TEST RESULTS"
    Write-Host "======================================================================"
    Write-Host "Total servers tested: $($servers.Count)"
    Write-Host "Working servers:      $($working.Count) ($successRate%)"
    Write-Host "Failed servers:       $($failed.Count)"
    Write-Host "Test duration:        $elapsed seconds"
    Write-Host "Test domain:          $testDomain"
    Write-Host ""
    
    if ($working.Count -gt 0) {
        Write-Host "TOP 5 FASTEST SERVERS:"
        $topServers = $working | Sort-Object ResponseTime | Select-Object -First 5
        $rank = 1
        foreach ($srv in $topServers) {
            Write-Host ("  {0}. {1,-15} {2}ms" -f $rank, $srv.Server, $srv.ResponseTime)
            $rank++
        }
        if ($working.Count -gt 5) {
            Write-Host "  ... $($working.Count - 5) more servers"
        }
        Write-Host ""
    }
    
    Write-Host "Results saved: $OutputFile ($($working.Count) servers)"
    Write-Host "======================================================================"
    Write-Host ""
    Write-Host "Testing complete!"
}

# Run main function
Main
