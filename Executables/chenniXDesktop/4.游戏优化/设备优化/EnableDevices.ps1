$instanceIds = @(
    'ROOT\CompositeBus\0000'
    'ROOT\vdrvroot\0000'
    'ROOT\UMBUS\0000'
    'ROOT\NdisVirtualBus\0000'
)

foreach ($id in $instanceIds) {
    $dev = Get-PnpDevice -InstanceId $id -ErrorAction Ignore
    if ($dev) {
        $dev | Enable-PnpDevice -Confirm:$false -ErrorAction Ignore
        Write-Host "  Enabled: $($dev.FriendlyName) [$id]"
    }
}

exit