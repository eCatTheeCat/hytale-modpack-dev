$client = [System.Net.Sockets.UdpClient]::new()
$client.Client.ReceiveTimeout = 1000  # 1 second

$ip = [System.Net.IPAddress]::Parse("127.0.0.1")
$endpoint = New-Object System.Net.IPEndPoint($ip, 5520)

# Send a dummy packet
[void]$client.Send([byte[]]@(0), 1, $endpoint)

try {
    $remote = $null
    [void]$client.Receive([ref]$remote)
    Write-Host "Server responded"
}
catch {
    Write-Host "No response (server may be down, hung, or ignoring this packet)"
}
finally {
    $client.Close()
}