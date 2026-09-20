$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------
# Parametros del modelo (unico bloque que cambia entre paquetes)
# ---------------------------------------------------------------
$packageName  = 'l3210'
$folderName   = 'reset-epson-l3210'
$releaseTag   = 'L3210'
$zipName      = 'Reset-Epson-L3210.zip'
$exeName      = 'Reset-Epson-L3210.exe'
$checksum     = '3ed106f6344e84b858fdb375e0afe9ffb52e741957222df1cc9c25ebaf6aec64'
$shortcutName = 'Reset Epson L3210.lnk'

# ---------------------------------------------------------------
# Constantes comunes a todos los paquetes
# ---------------------------------------------------------------
$baseUrl     = 'https://github.com/resetentupc/ResetDownloads/releases/download'
$installRoot = 'c:\resetentupc.com'

$url          = "$baseUrl/$releaseTag/$zipName"
$installDir   = Join-Path $installRoot $folderName
$exePath      = Join-Path $installDir $exeName
$desktopDir   = [Environment]::GetFolderPath('CommonDesktopDirectory')
$shortcutPath = Join-Path $desktopDir $shortcutName

# Salvaguarda: solo se puede borrar/escribir dentro de la carpeta propia del paquete.
if ([string]::IsNullOrWhiteSpace($folderName) -or
    -not $installDir.StartsWith("$installRoot\", [StringComparison]::OrdinalIgnoreCase)) {
    throw "Ruta de instalacion invalida: '$installDir'"
}

# ---------------------------------------------------------------
# Limpieza previa (idempotencia: reinstalacion / actualizacion)
# Solo se elimina lo que crea este paquete.
# ---------------------------------------------------------------
if (Test-Path -LiteralPath $shortcutPath) {
    Write-Host "Eliminando acceso directo anterior: $shortcutPath"
    Remove-Item -LiteralPath $shortcutPath -Force
}

if (Test-Path -LiteralPath $installDir) {
    Write-Host "Eliminando instalacion anterior: $installDir"
    Remove-Item -LiteralPath $installDir -Recurse -Force
}

New-Item -ItemType Directory -Path $installDir -Force | Out-Null

# ---------------------------------------------------------------
# Descarga (con SHA256 obligatorio) y extraccion
# ---------------------------------------------------------------
Install-ChocolateyZipPackage `
    -PackageName  $packageName `
    -Url          $url `
    -UnzipLocation $installDir `
    -Checksum     $checksum `
    -ChecksumType 'sha256'

# ---------------------------------------------------------------
# Asegurar que el ejecutable quede en la raiz de la carpeta de instalacion.
# Si el ZIP trae una unica carpeta contenedora, se sube su contenido un nivel.
# ---------------------------------------------------------------
if (-not (Test-Path -LiteralPath $exePath -PathType Leaf)) {
    $items = @(Get-ChildItem -LiteralPath $installDir -Force)

    if ($items.Count -eq 1 -and $items[0].PSIsContainer) {
        $subDir = $items[0].FullName
        Get-ChildItem -LiteralPath $subDir -Force |
            Move-Item -Destination $installDir -Force
        Remove-Item -LiteralPath $subDir -Force
    }
}

if (-not (Test-Path -LiteralPath $exePath -PathType Leaf)) {
    throw "No se encontro '$exeName' en '$installDir' tras extraer el ZIP."
}

# ---------------------------------------------------------------
# Acceso directo en el Escritorio publico
# ---------------------------------------------------------------
Install-ChocolateyShortcut `
    -ShortcutFilePath $shortcutPath `
    -TargetPath       $exePath `
    -WorkingDirectory $installDir `
    -Description      "Reset Epson L3210 - ResetEntuPc"

Write-Host "Instalacion completada: $exePath"
