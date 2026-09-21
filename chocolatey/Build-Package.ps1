<#
.SYNOPSIS
    Genera paquetes Chocolatey de ResetEntuPc para herramientas de reset Epson.

.DESCRIPTION
    Contiene la plantilla maestra (nuspec, chocolateyInstall.ps1 y
    chocolateyUninstall.ps1) y una tabla Modelo -> SHA256. A partir del modelo
    deriva packageName (id corto: l3210), carpeta de instalacion (reset-epson-l3210),
    tag, ZIP, EXE y acceso directo, y genera la carpeta del paquete. No descarga
    nada. Solo escribe en <OutputRoot>\<packageName>.

.PARAMETER Model
    Modelo(s) a generar, por ejemplo L3210. Acepta varios: -Model L3250,L3260

.PARAMETER Version
    Version del paquete. Por defecto 1.0.0.

.PARAMETER InstallRoot
    Carpeta raiz de instalacion en el equipo destino. Por defecto c:\resetentupc.com

.PARAMETER OutputRoot
    Carpeta donde se crea cada paquete. Por defecto, la carpeta de este script.

.PARAMETER Sha256
    SHA256 del ZIP del modelo (64 caracteres hexadecimales). Opcional. Si se indica,
    se usa en lugar de la tabla, lo que permite generar modelos que aun no estan
    registrados (lo usa el flujo automatico de GitHub Actions). Solo con un modelo.

.PARAMETER ReleaseTag
    Tag real del release de GitHub donde esta el ZIP. Opcional. Por defecto es el
    propio modelo (por ejemplo L3210). Se usa cuando el tag no coincide con el modelo
    (por ejemplo ET-2850-22). Solo con un modelo.

.PARAMETER ZipName
    Nombre real del ZIP en el release. Opcional. Por defecto Reset-Epson-<modelo>.zip.
    Se usa cuando el nombre difiere (por ejemplo Reset-EPSON-L382.zip). Solo con un modelo.

.PARAMETER Pack
    Ejecuta 'choco pack' sobre el paquete generado (requiere Chocolatey).

.EXAMPLE
    .\Build-Package.ps1 -Model L3210

.EXAMPLE
    .\Build-Package.ps1 -Model L1250 -Sha256 <hash del ZIP> -Pack

.EXAMPLE
    .\Build-Package.ps1 -Model L3250,L3260 -Pack

.EXAMPLE
    .\Build-Package.ps1 -Model L3210 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidatePattern('^(L|M|ET-|WF-|XP-|SP-|CX-|SC-P|Artisan-)\d{3,4}$')]
    [string[]]$Model,

    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$Version = '1.0.0',

    [ValidatePattern('^[A-Za-z]:\\[\w .\\-]+$')]
    [string]$InstallRoot = 'c:\resetentupc.com',

    [string]$OutputRoot = $PSScriptRoot,

    [ValidatePattern('^[0-9a-fA-F]{64}$')]
    [string]$Sha256,

    [ValidatePattern('^[A-Za-z0-9._-]+$')]
    [string]$ReleaseTag,

    [ValidatePattern('^[A-Za-z0-9._-]+\.zip$')]
    [string]$ZipName,

    [switch]$Pack
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------
# Datos fijos y tabla de modelos (agregar aqui los modelos nuevos)
# ---------------------------------------------------------------
$RepoUrl = 'https://github.com/resetentupc/ResetDownloads'
$BaseUrl = "$RepoUrl/releases/download"

$Models = [ordered]@{
    'L3210' = '3ed106f6344e84b858fdb375e0afe9ffb52e741957222df1cc9c25ebaf6aec64'
    'L3250' = '9821586b47f7ebfd01047bb3fd555b8027eca3705d4d952f6c711a591120df8a'
    'L3260' = 'cae02723d919de42bb21d96265bd08cb3c18e0b5c522bac871fe7008bc3f6b66'
}

# ---------------------------------------------------------------
# Plantilla: .nuspec
# ---------------------------------------------------------------
$NuspecTemplate = @'
<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://schemas.microsoft.com/packaging/2015/06/nuspec.xsd">
  <metadata>
    <id>{{PackageName}}</id>
    <version>{{Version}}</version>
    <title>{{Title}}</title>
    <authors>ResetEntuPc</authors>
    <owners>ResetEntuPc</owners>

    <projectUrl>https://resetentupc.com</projectUrl>
    <projectSourceUrl>{{RepoUrl}}</projectSourceUrl>
    <packageSourceUrl>{{RepoUrl}}</packageSourceUrl>

    <description>
      Herramienta de Reset para {{ModelName}} distribuida por ResetEntuPc.

      Este paquete descarga el archivo {{ZipName}} desde GitHub Releases
      ({{RepoUrl}}), verifica su integridad mediante SHA256,
      lo instala en {{InstallRoot}}\{{FolderName}} y crea el acceso directo
      "{{Title}}".
    </description>

    <summary>{{Title}}</summary>

    <releaseNotes>Versi&#243;n inicial.</releaseNotes>

    <tags>
      epson {{ModelLower}} reset impresora resetentupc
    </tags>

    <requireLicenseAcceptance>false</requireLicenseAcceptance>
  </metadata>

  <files>
    <file src="tools\**" target="tools" />
  </files>
</package>
'@

# ---------------------------------------------------------------
# Plantilla: chocolateyInstall.ps1
# ---------------------------------------------------------------
$InstallTemplate = @'
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------
# Parametros del modelo (unico bloque que cambia entre paquetes)
# ---------------------------------------------------------------
$packageName  = '{{PackageName}}'
$folderName   = '{{FolderName}}'
$releaseTag   = '{{ReleaseTag}}'
$zipName      = '{{ZipName}}'
$exeName      = '{{ExeName}}'
$checksum     = '{{Sha256}}'
$shortcutName = '{{ShortcutName}}'

# ---------------------------------------------------------------
# Constantes comunes a todos los paquetes
# ---------------------------------------------------------------
$baseUrl     = '{{BaseUrl}}'
$installRoot = '{{InstallRoot}}'

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
    -Description      "{{Title}} - ResetEntuPc"

Write-Host "Instalacion completada: $exePath"
'@

# ---------------------------------------------------------------
# Plantilla: chocolateyUninstall.ps1
# ---------------------------------------------------------------
$UninstallTemplate = @'
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------
# Parametros del modelo (deben coincidir con chocolateyInstall.ps1)
# ---------------------------------------------------------------
$packageName  = '{{PackageName}}'
$folderName   = '{{FolderName}}'
$shortcutName = '{{ShortcutName}}'

# ---------------------------------------------------------------
# Constantes comunes a todos los paquetes
# ---------------------------------------------------------------
$installRoot  = '{{InstallRoot}}'

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
'@

# ---------------------------------------------------------------
# Utilidades
# ---------------------------------------------------------------
function Expand-Template {
    param(
        [Parameter(Mandatory)][string]$Template,
        [Parameter(Mandatory)][hashtable]$Tokens
    )

    $text = $Template
    foreach ($key in $Tokens.Keys) {
        $text = $text.Replace("{{$key}}", [string]$Tokens[$key])
    }

    if ($text -match '\{\{\w+\}\}') {
        throw "Plantilla con marcador sin resolver: $($Matches[0])"
    }

    # Normaliza a CRLF y termina con salto de linea.
    ($text.TrimEnd() -replace "`r?`n", "`r`n") + "`r`n"
}

$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$InstallRoot = $InstallRoot.TrimEnd('\')

# ---------------------------------------------------------------
# Generacion
# ---------------------------------------------------------------
if ($Model.Count -ne 1 -and ($PSBoundParameters.ContainsKey('ReleaseTag') -or $PSBoundParameters.ContainsKey('ZipName'))) {
    throw "-ReleaseTag y -ZipName solo se pueden usar con un unico modelo."
}

foreach ($item in $Model) {
    $modelId = $item.ToUpperInvariant() -replace '^ARTISAN-', 'Artisan-'

    if ($PSBoundParameters.ContainsKey('Sha256')) {
        if ($Model.Count -ne 1) {
            throw "-Sha256 solo se puede usar con un unico modelo."
        }
        $sha256 = $Sha256.ToLowerInvariant()
    }
    elseif ($Models.Contains($modelId)) {
        $sha256 = $Models[$modelId]
    }
    else {
        throw "Modelo '$modelId' no registrado. Use -Sha256 o agreguelo a la tabla. Modelos registrados: $($Models.Keys -join ', ')"
    }

    if ($sha256 -notmatch '^[0-9a-f]{64}$') {
        throw "SHA256 invalido para el modelo '$modelId'."
    }

    $packageName = $modelId.ToLowerInvariant()
    $folderName  = "reset-epson-$packageName"

    $tokens = @{
        PackageName  = $packageName
        FolderName   = $folderName
        Version      = $Version
        Title        = "Reset Epson $modelId"
        ModelName    = "Epson $modelId"
        ModelLower   = $modelId.ToLowerInvariant()
        ReleaseTag   = $(if ($PSBoundParameters.ContainsKey('ReleaseTag')) { $ReleaseTag } else { $modelId })
        ZipName      = $(if ($PSBoundParameters.ContainsKey('ZipName')) { $ZipName } else { "Reset-Epson-$modelId.zip" })
        ExeName      = "Reset-Epson-$modelId.exe"
        ShortcutName = "Reset Epson $modelId.lnk"
        Sha256       = $sha256
        InstallRoot  = $InstallRoot
        BaseUrl      = $BaseUrl
        RepoUrl      = $RepoUrl
    }

    $packageDir  = Join-Path $OutputRoot $packageName
    $toolsDir    = Join-Path $packageDir 'tools'
    $nuspecPath  = Join-Path $packageDir "$packageName.nuspec"

    $outputs = @(
        @{ Path = $nuspecPath;                                     Template = $NuspecTemplate }
        @{ Path = (Join-Path $toolsDir 'chocolateyInstall.ps1');   Template = $InstallTemplate }
        @{ Path = (Join-Path $toolsDir 'chocolateyUninstall.ps1'); Template = $UninstallTemplate }
    )

    Write-Host "Modelo $modelId -> $packageDir"

    foreach ($out in $outputs) {
        $content = Expand-Template -Template $out.Template -Tokens $tokens

        if ($PSCmdlet.ShouldProcess($out.Path, 'Generar archivo')) {
            New-Item -ItemType Directory -Path (Split-Path -Parent $out.Path) -Force | Out-Null
            [System.IO.File]::WriteAllText($out.Path, $content, $Utf8NoBom)
            Write-Host "  Generado: $($out.Path)"
        }
    }

    if ($Pack) {
        if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
            throw "No se encontro 'choco' en el PATH. Instale Chocolatey o ejecute sin -Pack."
        }

        if ($PSCmdlet.ShouldProcess($nuspecPath, 'choco pack')) {
            Push-Location $packageDir
            try {
                & choco pack $nuspecPath
                if ($LASTEXITCODE -ne 0) {
                    throw "choco pack fallo para '$packageName' (codigo $LASTEXITCODE)."
                }
            }
            finally {
                Pop-Location
            }
        }
    }

    Write-Host "  Instalacion local con una linea:"
    Write-Host "    choco install $packageName -y -s `"$packageDir`""
}
