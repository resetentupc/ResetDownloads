$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------
# Parametros del modelo (deben coincidir con chocolateyInstall.ps1)
# ---------------------------------------------------------------
$packageName  = 'l3210'
$folderName   = 'reset-epson-l3210'
$shortcutName = 'Reset Epson L3210.lnk'

# ---------------------------------------------------------------
# Constantes comunes a todos los paquetes
# ---------------------------------------------------------------
$installRoot  = 'c:\resetentupc.com'

$installDir   = Join-Path $installRoot $folderName
$desktopDir   = [Environment]::GetFolderPath('CommonDesktopDirectory')
$shortcutPath = Join-Path $desktopDir $shortcutName

# Salvaguarda: solo se puede borrar dentro de la carpeta propia del paquete.
if ([string]::IsNullOrWhiteSpace($folderName) -or
    -not $installDir.StartsWith("$installRoot\", [StringComparison]::OrdinalIgnoreCase)) {
    throw "Ruta de instalacion invalida: '$installDir'"
}

# ---------------------------------------------------------------
# Eliminar unicamente lo creado por este paquete
# ---------------------------------------------------------------
if (Test-Path -LiteralPath $shortcutPath) {
    Write-Host "Eliminando acceso directo: $shortcutPath"
    Remove-Item -LiteralPath $shortcutPath -Force
}

if (Test-Path -LiteralPath $installDir) {
    Write-Host "Eliminando carpeta de instalacion: $installDir"
    try {
        Remove-Item -LiteralPath $installDir -Recurse -Force
    }
    catch {
        throw "No se pudo eliminar '$installDir'. Cierre '$packageName' si esta en ejecucion y reintente. Detalle: $($_.Exception.Message)"
    }
}

Write-Host "Desinstalacion completada: $packageName"
