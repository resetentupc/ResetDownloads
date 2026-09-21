<#
.SYNOPSIS
    Genera gestor/modelos.json: la lista de modelos que lee el instalador de ResetEntuPC.com.

.DESCRIPTION
    Lee los releases públicos de github.com/resetentupc/ResetDownloads (solo lectura) y escribe
    un JSON con un modelo por línea: nombre, id del paquete, etiqueta del release y URL exacta
    del .nupkg. El instalador descarga ese archivo (raw) al abrirse y con el botón
    "Actualizar lista de modelos"; así, un modelo nuevo aparece sin volver a distribuir el .exe.

    - Si la lista de modelos no cambia, NO toca el archivo (la fecha no genera cambios).
    - Si la lista nueva es mucho más corta que la anterior (posible respuesta incompleta de
      GitHub), se detiene sin cambiar nada. Se puede forzar con -Forzar.
    - Si existe GITHUB_TOKEN (la GitHub Action lo aporta sola), se usa solo para evitar el
      límite de consultas anónimas. No hace falta en local.

    Lo ejecuta la GitHub Action "Actualizar lista de modelos" cada vez que se genera un .nupkg
    nuevo. También se puede lanzar a mano.

.PARAMETER Salida
    Archivo JSON a escribir (por defecto, modelos.json junto a este script).

.PARAMETER Forzar
    Permite aceptar una lista mucho más corta que la anterior.

.PARAMETER WhatIf
    Solo muestra los cambios, sin escribir nada.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Salida = (Join-Path $PSScriptRoot 'modelos.json'),
    [string]$Repo = 'resetentupc/ResetDownloads',
    [switch]$Forzar
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# Mismos patrones que valida el instalador: lo que no encaje no entra en la lista.
$patronId  = '^(l|m|et-|wf-|xp-|sp-|cx-|sc-p|artisan-)\d{3,4}$'
$patronTag = '^[A-Za-z0-9][A-Za-z0-9._-]{0,60}$'
$baseDescarga = "https://github.com/$Repo/releases/download"

# 1) Leer los releases (del más nuevo al más antiguo)
$cab = @{ 'User-Agent' = 'ResetEntuPC-ListaModelos'; 'Accept' = 'application/vnd.github+json' }
if ($env:GITHUB_TOKEN) { $cab['Authorization'] = "Bearer $($env:GITHUB_TOKEN)" }
$releases = @()
foreach ($pg in 1..10) {
    $resp = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases?per_page=100&page=$pg" -Headers $cab -TimeoutSec 30
    $lote = @($resp | ForEach-Object { $_ })
    if ($lote.Count -eq 0) { break }
    $releases += $lote
    if ($lote.Count -lt 100) { break }
}

$vistos = @{}
$filas = New-Object System.Collections.Generic.List[object]
$descartados = @()
foreach ($rel in $releases) {
    foreach ($a in @($rel.assets)) {
        if ($a.name -notlike '*.1.0.0.nupkg') { continue }
        $id = $a.name -replace '\.1\.0\.0\.nupkg$', ''
        $tag = [string]$rel.tag_name
        if ($id -cnotmatch $patronId -or $tag -notmatch $patronTag) { $descartados += "$($a.name) (etiqueta $tag)"; continue }
        if ($vistos.ContainsKey($id)) { continue }
        $vistos[$id] = $true
        $nombre = $id.ToUpperInvariant() -replace '^ARTISAN-', 'Artisan-'
        $filas.Add([pscustomobject]@{ Modelo = $nombre; Id = $id; Tag = $tag; Url = "$baseDescarga/$tag/$id.1.0.0.nupkg" })
    }
}
if ($filas.Count -eq 0) { throw 'GitHub no devolvió ningún paquete válido; no se cambia nada.' }
$ordenadas = @($filas | Sort-Object @{ Expression = { $_.Id -replace '\d+$', '' } }, @{ Expression = { [int]($_.Id -replace '^\D+', '') } })

# 2) Construir el cuerpo (un modelo por línea: los cambios se leen bien en git) y compararlo
$lineas = @($ordenadas | ForEach-Object { '    { "modelo": "' + $_.Modelo + '", "id": "' + $_.Id + '", "tag": "' + $_.Tag + '", "url": "' + $_.Url + '" }' })
$cuerpo = $lineas -join ",`n"

$anterior = ''
$antes = @()
if (Test-Path -LiteralPath $Salida) {
    $anterior = [IO.File]::ReadAllText($Salida).Replace("`r`n", "`n")
    $antes = @([regex]::Matches($anterior, '"id":\s*"([^"]+)"') | ForEach-Object { $_.Groups[1].Value })
}
$ahora = @($ordenadas | ForEach-Object { $_.Id })
$nuevos = @($ahora | Where-Object { $antes -notcontains $_ })
$quitados = @($antes | Where-Object { $ahora -notcontains $_ })

"Modelos en GitHub: $($ahora.Count)   (antes en el archivo: $($antes.Count))"
"Añadidos ($($nuevos.Count)): " + ($nuevos -join ', ')
"Quitados ($($quitados.Count)): " + ($quitados -join ', ')
if ($descartados.Count) { "Descartados por no cumplir el patrón ($($descartados.Count)): " + ($descartados -join '; ') }

# Sin cambios en los modelos (ids, etiquetas y URLs): no se toca el archivo, ni siquiera la fecha.
if ($anterior -and $anterior.Contains("`"modelos`": [`n$cuerpo`n  ]")) { 'La lista ya estaba al día. No se cambia nada.'; return }

# Protección: una lista mucho más corta suele ser una respuesta incompleta de GitHub.
if (-not $Forzar -and $antes.Count -ge 10 -and $ahora.Count -lt [math]::Floor($antes.Count * 0.7)) {
    throw "La lista nueva ($($ahora.Count)) es mucho más corta que la anterior ($($antes.Count)). No se cambia nada; usa -Forzar si es correcto."
}

$fecha = Get-Date -Format 'yyyy-MM-dd'
$json = "{`n  `"version`": 1,`n  `"actualizado`": `"$fecha`",`n  `"modelos`": [`n$cuerpo`n  ]`n}`n"

# 3) Escribir (UTF-8 sin BOM, saltos LF) y comprobar que se puede leer de vuelta
if ($PSCmdlet.ShouldProcess($Salida, "Escribir la lista de modelos ($($ahora.Count) modelos, $fecha)")) {
    [IO.File]::WriteAllText($Salida, $json, (New-Object System.Text.UTF8Encoding($false)))
    $leido = [IO.File]::ReadAllText($Salida) | ConvertFrom-Json
    if (@($leido.modelos).Count -ne $ahora.Count) {
        if ($anterior) { [IO.File]::WriteAllText($Salida, $anterior, (New-Object System.Text.UTF8Encoding($false))) }
        throw 'El JSON escrito no se pudo leer de vuelta con el número esperado de modelos; se restauró el original.'
    }
    "Lista de modelos escrita: $($ahora.Count) modelos ($fecha). JSON válido."
}
