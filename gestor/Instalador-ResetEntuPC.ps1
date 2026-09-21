<#
.SYNOPSIS
    Instalador - ResetEntuPC.com (Reset Epson: solución al Error de Almohadillas)

.DESCRIPTION
    Aplicación de escritorio (Windows Forms) de un solo archivo para buscar el modelo de
    impresora Epson e instalar, reinstalar o desinstalar su herramienta con Chocolatey.

    - Diccionario INTERNO de modelos (nombre -> URL exacta y paquete): las Releases de GitHub tienen
      sufijos irregulares (ET-2850-22, L120-22.1, CX-5600-original, XP-431-16...), así que la URL de
      descarga NUNCA se construye a partir del nombre: se lee del diccionario. Además, al abrirse descarga
      modelos.json del repositorio de GitHub, y el botón "Actualizar lista de modelos" vuelve
      a descargarlo sin cerrar el programa y añade los modelos NUEVOS. Si un modelo está en las dos
      listas, MANDA EL DICCIONARIO INTERNO. La última lista buena se guarda en
      %LOCALAPPDATA%\ResetEntuPC\ para poder abrir el programa sin conexión.
    - Panel de políticas del servicio siempre visible, y casilla obligatoria de aceptación:
      sin marcarla, Instalar y Reinstalar permanecen bloqueados.
    - Al terminar una instalación con éxito muestra el "Paso final" con un único botón de
      WhatsApp (el PC ID es opcional).
    - Los comandos de Chocolatey se ejecutan en segundo plano, sin congelar la ventana.

    Seguridad:
    - Solo descarga desde https://github.com/resetentupc/ResetDownloads/releases/download/
      La URL de cada modelo del JSON debe coincidir EXACTAMENTE con esa dirección; el id y la
      etiqueta se validan con patrones estrictos y se pasan al comando como variables (nunca se
      pegan dentro del texto del comando). Lo que no encaje se descarta.
    - No instala Chocolatey por su cuenta y NO cambia ninguna configuración de seguridad de
      Windows (ni exclusiones de antivirus). Solo muestra un aviso sobre otros antivirus.

    Requisito: Chocolatey instalado (https://chocolatey.org/install).

    Empaquetado en .exe (p. ej. con PS2EXE): compílalo con los parámetros -noConsole -STA
    -requireAdmin. Con -requireAdmin, Windows pide los permisos antes de abrir la aplicación
    (la autoelevación de abajo solo se usa al ejecutar el .ps1 directamente).

.PARAMETER Modelo
    Opcional. Modelo que aparece ya buscado al abrir (por ejemplo: L3210).

.PARAMETER Prueba
    Modo demostración: NO pide administrador, NO usa la red ni la copia guardada y NO instala
    nada. Usa solo el diccionario interno y los botones ejecutan una simulación inofensiva.

.NOTES
    Guardar con codificación UTF-8 con BOM (por los acentos). Ejecutar con clic derecho >
    "Ejecutar con PowerShell", o:  powershell -STA -File .\Instalador-ResetEntuPC.ps1
#>
[CmdletBinding()]
param(
    [string]$Modelo = '',
    [switch]$Prueba
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms, System.Drawing

# ============================================================================
# 1. ELEVACIÓN DE PRIVILEGIOS
#    Si no somos administradores, se relanza este mismo archivo con "RunAs".
#    (El aviso UAC de Windows es obligatorio y no se puede ni se debe ocultar.)
# ============================================================================
function Test-EsAdministrador {
    $identidad = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identidad)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not $Prueba -and -not (Test-EsAdministrador)) {
    if ([string]::IsNullOrEmpty($PSCommandPath)) {
        [void][Windows.Forms.MessageBox]::Show(
            'Este programa necesita permisos de administrador. Ciérralo y ábrelo con clic derecho > "Ejecutar como administrador".',
            'ResetEntuPC.com', 'OK', 'Warning')
        exit 1
    }
    try {
        $argumentos = @('-NoProfile', '-STA', '-WindowStyle', 'Hidden', '-File', ('"{0}"' -f $PSCommandPath))
        if ($Modelo -match '^[A-Za-z0-9-]{1,20}$') { $argumentos += @('-Modelo', $Modelo) }
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argumentos
    }
    catch {
        [void][Windows.Forms.MessageBox]::Show(
            'Se necesitan permisos de administrador para usar Chocolatey. Ejecuta de nuevo el programa y acepta el aviso de Windows.',
            'ResetEntuPC.com', 'OK', 'Warning')
    }
    exit
}

# Pantallas con escala alta (125 %, 150 %...): evita que Windows difumine la ventana.
try {
    Add-Type -Namespace Win32 -Name Dpi -MemberDefinition '[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetProcessDPIAware();'
    [void][Win32.Dpi]::SetProcessDPIAware()
} catch { }
# Texto de fondo dentro de la caja de búsqueda.
try {
    Add-Type -Namespace Win32 -Name Cue -MemberDefinition '[System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)] public static extern System.IntPtr SendMessage(System.IntPtr h, int m, System.IntPtr w, string l);'
} catch { }
[Windows.Forms.Application]::EnableVisualStyles()

# Elemento de la lista de modelos (se muestra el nombre; id, etiqueta y URL viajan con él).
if (-not ('ModeloItem' -as [type])) {
    Add-Type -TypeDefinition @'
public class ModeloItem {
    public string Modelo;
    public string Id;
    public string Tag;
    public string Url;
    public string Nupkg;
    public override string ToString() { return Modelo; }
}
'@
}

# ============================================================================
# 2. CONFIGURACIÓN
# ============================================================================
$script:Prueba        = [bool]$Prueba
$script:ModeloInicial = $Modelo
$script:Version       = '3.0'

# Dónde está la lista de modelos (archivo "raw" del repositorio; lo mantiene al día una GitHub Action).
$script:ListaUrl     = 'https://raw.githubusercontent.com/resetentupc/ResetDownloads/main/gestor/modelos.json'
$script:BaseDescarga = 'https://github.com/resetentupc/ResetDownloads/releases/download'
# Última lista buena, para poder abrir el programa sin conexión.
$script:CacheDir     = Join-Path $env:LOCALAPPDATA 'ResetEntuPC'
$script:CacheFile    = Join-Path $script:CacheDir 'modelos.json'

# Patrones estrictos: lo que no encaje aquí NO se ofrece ni se ejecuta.
$script:PatronId  = '^(l|m|et-|wf-|xp-|sp-|cx-|sc-p|artisan-)\d{3,4}$'
$script:PatronTag = '^[A-Za-z0-9][A-Za-z0-9._-]{0,60}$'

# Diccionario INTERNO de modelos: nombre del modelo -> paquete (.nupkg) y URL EXACTA de su Release.
# Las etiquetas de las Releases son irregulares (ET-2850-22, L120-22.1, CX-5600-original, XP-431-16...),
# por eso la URL NUNCA se construye a partir del nombre del modelo: se lee de aquí.
# Si la lista en línea (modelos.json) trae un modelo que ya está aquí, MANDA ESTE DICCIONARIO.
# Formato por línea: Modelo|paquete.nupkg|URL   (se valida al cargar: patrones estrictos y URL exacta).
# >>> DICCIONARIO-INICIO <<<
$script:DiccionarioTexto = @'
Artisan-1430|artisan-1430.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/Artisan-1430/artisan-1430.1.0.0.nupkg
CX-5600|cx-5600.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/CX-5600-original/cx-5600.1.0.0.nupkg
ET-1810|et-1810.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/ET-1810/et-1810.1.0.0.nupkg
ET-2400|et-2400.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/ET-2400/et-2400.1.0.0.nupkg
ET-2500|et-2500.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/ET-2500/et-2500.1.0.0.nupkg
ET-2550|et-2550.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/ET-2550/et-2550.1.0.0.nupkg
ET-2600|et-2600.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/ET-2600/et-2600.1.0.0.nupkg
ET-2610|et-2610.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/ET-2610/et-2610.1.0.0.nupkg
ET-2650|et-2650.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/ET-2650/et-2650.1.0.0.nupkg
ET-2710|et-2710.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/ET-2710/et-2710.1.0.0.nupkg
ET-2720|et-2720.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/ET-2720/et-2720.1.0.0.nupkg
ET-2750|et-2750.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/ET-2750/et-2750.1.0.0.nupkg
ET-2760|et-2760.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/ET-2760/et-2760.1.0.0.nupkg
ET-2800|et-2800.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/ET-2800/et-2800.1.0.0.nupkg
ET-2803|et-2803.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/ET-2803/et-2803.1.0.0.nupkg
ET-2810|et-2810.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/ET-2810/et-2810.1.0.0.nupkg
ET-2820|et-2820.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/ET-2820/et-2820.1.0.0.nupkg
ET-2850|et-2850.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/ET-2850-22/et-2850.1.0.0.nupkg
ET-2860|et-2860.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/ET-2860/et-2860.1.0.0.nupkg
ET-2870|et-2870.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/ET-2870/et-2870.1.0.0.nupkg
ET-3710|et-3710.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/ET-3710/et-3710.1.0.0.nupkg
ET-4500|et-4500.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/ET-4500-22/et-4500.1.0.0.nupkg
ET-4550|et-4550.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/ET-4550/et-4550.1.0.0.nupkg
ET-4800|et-4800.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/ET-4800/et-4800.1.0.0.nupkg
L110|l110.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/L110-22/l110.1.0.0.nupkg
L120|l120.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/L120-22.1/l120.1.0.0.nupkg
L121|l121.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/L121-22.1/l121.1.0.0.nupkg
L130|l130.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/L130-22/l130.1.0.0.nupkg
L200|l200.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/L200-22/l200.1.0.0.nupkg
L210|l210.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/L210-22/l210.1.0.0.nupkg
L220|l220.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/L220-22/l220.1.0.0.nupkg
L310|l310.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/L310-22/l310.1.0.0.nupkg
L350|l350.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/L350-22/l350.1.0.0.nupkg
L355|l355.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/L355-22/l355.1.0.0.nupkg
L360|l360.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/L360-22/l360.1.0.0.nupkg
L365|l365.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/L365-22/l365.1.0.0.nupkg
L375|l375.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/L375-22.1/l375.1.0.0.nupkg
L380|l380.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/L380-22/l380.1.0.0.nupkg
L382|l382.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/L382/l382.1.0.0.nupkg
L385|l385.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/L385/l385.1.0.0.nupkg
L395|l395.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/L395-22/l395.1.0.0.nupkg
L396|l396.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/L396-22/l396.1.0.0.nupkg
L455|l455.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/L455-22/l455.1.0.0.nupkg
L475|l475.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/L475-22.1/l475.1.0.0.nupkg
L485|l485.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/L485/l485.1.0.0.nupkg
L495|l495.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/L495-22/l495.1.0.0.nupkg
L550|l550.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/L550-22/l550.1.0.0.nupkg
L555|l555.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/L555-22/l555.1.0.0.nupkg
L565|l565.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/L565-22/l565.1.0.0.nupkg
L575|l575.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/L575-22/l575.1.0.0.nupkg
L605|l605.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/L605-22/l605.1.0.0.nupkg
L606|l606.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/L606-22/l606.1.0.0.nupkg
L655|l655.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/L655-22.1/l655.1.0.0.nupkg
L656|l656.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/L656-22.1/l656.1.0.0.nupkg
L800|l800.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/L800-22/l800.1.0.0.nupkg
L805|l805.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/L805/l805.1.0.0.nupkg
L850|l850.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/L850/l850.1.0.0.nupkg
L1110|l1110.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/L1110/l1110.1.0.0.nupkg
L1210|l1210.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/L1210/l1210.1.0.0.nupkg
L1250|l1250.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/L1250/l1250.1.0.0.nupkg
L1300|l1300.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/L1300-22/l1300.1.0.0.nupkg
L1350|l1350.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/L1350/l1350.1.0.0.nupkg
L1800|l1800.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/L1800-22/l1800.1.0.0.nupkg
L3060|l3060.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/L3060/l3060.1.0.0.nupkg
L3110|l3110.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/L3110-22/l3110.1.0.0.nupkg
L3150|l3150.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/L3150/l3150.1.0.0.nupkg
L3160|l3160.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/L3160/l3160.1.0.0.nupkg
L3210|l3210.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/L3210/l3210.1.0.0.nupkg
L3250|l3250.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/L3250/l3250.1.0.0.nupkg
L3260|l3260.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/L3260/l3260.1.0.0.nupkg
L3310|l3310.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/L3310/l3310.1.0.0.nupkg
L3350|l3350.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/L3350/l3350.1.0.0.nupkg
L3360|l3360.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/L3360/l3360.1.0.0.nupkg
L4150|l4150.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/L4150/l4150.1.0.0.nupkg
L4160|l4160.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/L4160/l4160.1.0.0.nupkg
L4260|l4260.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/L4260-22/l4260.1.0.0.nupkg
L5190|l5190.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/L5190/l5190.1.0.0.nupkg
L5290|l5290.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/L5290/l5290.1.0.0.nupkg
L5390|l5390.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/L5390/l5390.1.0.0.nupkg
M1100|m1100.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/M1100/m1100.1.0.0.nupkg
M1120|m1120.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/M1120/m1120.1.0.0.nupkg
M2100|m2100.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/M2100/m2100.1.0.0.nupkg
M2120|m2120.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/M2120/m2120.1.0.0.nupkg
SC-P600|sc-p600.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/SC-P600/sc-p600.1.0.0.nupkg
SP-1390|sp-1390.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/SP-1390/sp-1390.1.0.0.nupkg
SP-1410|sp-1410.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/SP-1410/sp-1410.1.0.0.nupkg
WF-545|wf-545.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/WF-545/wf-545.1.0.0.nupkg
WF-645|wf-645.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/WF-645/wf-645.1.0.0.nupkg
WF-2520|wf-2520.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/WF-2520/wf-2520.1.0.0.nupkg
WF-2530|wf-2530.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/WF-2530/wf-2530.1.0.0.nupkg
WF-2540|wf-2540.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/WF-2540/wf-2540.1.0.0.nupkg
WF-2650|wf-2650.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/WF-2650/wf-2650.1.0.0.nupkg
WF-2660|wf-2660.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/WF-2660/wf-2660.1.0.0.nupkg
WF-2750|wf-2750.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/WF-2750/wf-2750.1.0.0.nupkg
WF-2760|wf-2760.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/WF-2760/wf-2760.1.0.0.nupkg
WF-3720|wf-3720.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/WF-3720/wf-3720.1.0.0.nupkg
WF-3725|wf-3725.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/WF-3725/wf-3725.1.0.0.nupkg
WF-3730|wf-3730.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/WF-3730/wf-3730.1.0.0.nupkg
WF-3733|wf-3733.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/WF-3733/wf-3733.1.0.0.nupkg
XP-101|xp-101.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/XP-101/xp-101.1.0.0.nupkg
XP-200|xp-200.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/XP-200/xp-200.1.0.0.nupkg
XP-201|xp-201.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/XP-201/xp-201.1.0.0.nupkg
XP-204|xp-204.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/XP-204/xp-204.1.0.0.nupkg
XP-211|xp-211.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/XP-211/xp-211.1.0.0.nupkg
XP-214|xp-214.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/XP-214/xp-214.1.0.0.nupkg
XP-231|xp-231.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/XP-235-16/xp-231.1.0.0.nupkg
XP-235|xp-235.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/XP-235/xp-235.1.0.0.nupkg
XP-240|xp-240.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/XP-240/xp-240.1.0.0.nupkg
XP-241|xp-241.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/XP-241/xp-241.1.0.0.nupkg
XP-243|xp-243.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/XP-243/xp-243.1.0.0.nupkg
XP-245|xp-245.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/XP-245/xp-245.1.0.0.nupkg
XP-255|xp-255.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/XP-255/xp-255.1.0.0.nupkg
XP-257|xp-257.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/XP-257/xp-257.1.0.0.nupkg
XP-300|xp-300.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/XP-300/xp-300.1.0.0.nupkg
XP-310|xp-310.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/XP-310/xp-310.1.0.0.nupkg
XP-320|xp-320.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/XP-320-16/xp-320.1.0.0.nupkg
XP-340|xp-340.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/XP-340/xp-340.1.0.0.nupkg
XP-345|xp-345.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/XP-345/xp-345.1.0.0.nupkg
XP-352|xp-352.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/XP-352/xp-352.1.0.0.nupkg
XP-355|xp-355.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/XP-355/xp-355.1.0.0.nupkg
XP-400|xp-400.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/XP-400/xp-400.1.0.0.nupkg
XP-401|xp-401.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/XP-401/xp-401.1.0.0.nupkg
XP-410|xp-410.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/XP-410/xp-410.1.0.0.nupkg
XP-411|xp-411.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/XP-411/xp-411.1.0.0.nupkg
XP-420|xp-420.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/XP-420-16/xp-420.1.0.0.nupkg
XP-424|xp-424.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/XP-424/xp-424.1.0.0.nupkg
XP-431|xp-431.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/XP-431-16/xp-431.1.0.0.nupkg
XP-432|xp-432.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/XP-432/xp-432.1.0.0.nupkg
XP-440|xp-440.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/XP-440/xp-440.1.0.0.nupkg
XP-445|xp-445.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/XP-445/xp-445.1.0.0.nupkg
XP-455|xp-455.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/XP-455/xp-455.1.0.0.nupkg
XP-620|xp-620.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/XP-620/xp-620.1.0.0.nupkg
XP-2100|xp-2100.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/XP-2100/xp-2100.1.0.0.nupkg
XP-2101|xp-2101.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/XP-2101/xp-2101.1.0.0.nupkg
XP-2105|xp-2105.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/XP-2105/xp-2105.1.0.0.nupkg
XP-2150|xp-2150.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/XP-2150/xp-2150.1.0.0.nupkg
XP-2155|xp-2155.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/XP-2155/xp-2155.1.0.0.nupkg
XP-2200|xp-2200.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/XP-2200/xp-2200.1.0.0.nupkg
XP-2201|xp-2201.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/XP-2201/xp-2201.1.0.0.nupkg
XP-2205|xp-2205.1.0.0.nupkg|https://github.com/resetentupc/ResetDownloads/releases/download/XP-2205/xp-2205.1.0.0.nupkg
'@
# >>> DICCIONARIO-FIN <<<

# Comandos: el id, la etiqueta, la URL EXACTA y el paquete del modelo elegido (salen del diccionario interno)
# entran como VARIABLES ($id, $tag, $url, $nupkg),
# ya validadas, definidas dentro del segundo plano. (Here-strings literales.)
$script:Comandos = [ordered]@{
    Instalar    = @'
$d="$env:TEMP\$id"; md $d -Force >$null; iwr $url -OutFile "$d\$nupkg" -UseBasicParsing; choco install $id -y -s $d
'@
    Reinstalar  = @'
$d="$env:TEMP\$id"; md $d -Force >$null; iwr $url -OutFile "$d\$nupkg" -UseBasicParsing; choco install $id -y -f -s $d
'@
    Desinstalar = @'
choco uninstall $id -y
'@
}

# En modo prueba se sustituyen por una simulación que no toca el sistema.
if ($script:Prueba) {
    foreach ($clave in @($script:Comandos.Keys)) {
        $script:Comandos[$clave] = 'Write-Output "[SIMULACIÓN] $id (etiqueta $tag): no se instala ni se cambia nada."; Start-Sleep -Seconds 2; Write-Output "[SIMULACIÓN] Terminado."; cmd /c exit 0'
    }
}

# Se ejecuta antes de cada comando dentro del segundo plano.
#  - Stop: si falla la descarga, no se sigue con choco.
#  - ProgressPreference: sin la barra de Invoke-WebRequest (la hace mucho más rápida en PS 5.1).
#  - TLS 1.2 añadido (solo AMPLÍA los protocolos permitidos; no desactiva ninguna validación).
$script:Preambulo = @'
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
'@

# Descarga el JSON de modelos en segundo plano (solo lectura). $url llega como variable.
# El parámetro anti-caché hace que "Actualizar" vea siempre la versión más reciente.
$script:GuionLista = @'
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
if ($url -match '^https://') {
    $r = Invoke-WebRequest -Uri ($url + '?nocache=' + [DateTime]::UtcNow.Ticks) -UseBasicParsing -TimeoutSec 20 -Headers @{ 'User-Agent' = 'ResetEntuPC-Instalador' }
    [string]$r.Content
}
else { Get-Content -LiteralPath $url -Raw -Encoding UTF8 }
'@

# Códigos de salida de choco que significan "correcto" (0 = ok; 1641/3010 = ok, pide reiniciar).
$script:CodigosOk = @('0', '1641', '3010')

# Contacto: un único canal, WhatsApp.
$script:WhatsAppNumero = '573245322603'
$script:WhatsAppVisible = '+57 324 532 2603'   # como se muestra en pantalla

# Políticas del servicio (texto obligatorio, siempre visible antes de instalar).
$script:Politicas = @(
    @{ Titulo = 'Alcance'; Texto = 'Este programa SOLO soluciona el Error de Almohadillas. NO repara errores físicos, calidad de impresión, caja de mantenimiento ni reconoce cartuchos.' },
    @{ Titulo = 'Licencia por modelo'; Texto = 'El pago es por la INSTALACIÓN DE UN SOLO MODELO. Seleccionar su modelo no le otorga derecho a usar el programa en todos los modelos ni en múltiples impresoras.' },
    @{ Titulo = 'Modalidad autónoma'; Texto = "Este es un servicio 'Hazlo tú mismo'. El procedimiento es 100% AUTÓNOMO por parte del cliente, NO es un servicio asistido." },
    @{ Titulo = 'Requisitos del sistema'; Texto = 'Funciona ÚNICAMENTE en Windows. NO es compatible con Mac, Linux ni celulares.' },
    @{ Titulo = 'Conexión física'; Texto = 'Es INDISPENSABLE tener la impresora conectada directamente al PC por CABLE USB.' },
    @{ Titulo = 'Uso offline'; Texto = 'Una vez finalizada la descarga e instalación, el programa puede usarse sin conexión a Internet.' },
    @{ Titulo = 'Política de permanencia'; Texto = 'Usted paga por una instalación. Si formatea su PC, elimina el programa o cambia de disco duro, PERDERÁ la instalación y deberá adquirir una nueva.' }
)
$script:TextoAceptacion = 'He leído las políticas: confirmo que uso Windows, cable USB, acepto que el proceso es autónomo y que si formateo pierdo la instalación.'
$script:AvisoAntivirus  = 'Si usa un antivirus diferente a Windows Defender, por favor páuselo temporalmente para evitar bloqueos en la instalación.'

# Paleta de colores
function New-Color([string]$hex) { [Drawing.ColorTranslator]::FromHtml($hex) }
$script:C = @{
    Fondo      = New-Color '#F1F5FA'
    Marino     = New-Color '#0F2A47'
    Acento     = New-Color '#1E6FD9'
    AcentoHov  = New-Color '#1758B0'
    # VERDE: reservado EXCLUSIVAMENTE para el botón de WhatsApp.
    WaVerde    = New-Color '#1EA952'
    WaVerdeHov = New-Color '#168A41'
    # ROJO: reservado EXCLUSIVAMENTE para acciones de descarga (botón Instalar).
    Rojo       = New-Color '#C0392B'
    RojoHov    = New-Color '#992E22'
    # NARANJA: reservado EXCLUSIVAMENTE para líneas divisorias, bordes y subrayados (nunca en botones ni textos).
    Naranja    = New-Color '#E0871A'
    # Botones generales: SOLO grises, grises azulados, azul claro y azul oscuro.
    AzulClaro     = New-Color '#4A8BD8'
    AzulClaroHov  = New-Color '#3B72B5'
    AzulOscuro    = New-Color '#1F4E8C'
    AzulOscuroHov = New-Color '#173C6B'
    GrisAzul      = New-Color '#5B6B80'
    GrisAzulHov   = New-Color '#465569'
    GrisOscuro    = New-Color '#3B4654'
    AvisoFondo    = New-Color '#EAF0F8'
    Deshab     = New-Color '#B8C2CE'
    Texto      = New-Color '#1B2733'
    Suave      = New-Color '#6B7A8C'
    Borde      = New-Color '#D8E0EB'
    Blanco     = [Drawing.Color]::White
    LogFondo   = New-Color '#0D1B2A'
    LogTexto   = New-Color '#C7E0FF'
}

# Estado y controles (los manejadores de eventos los leen desde $script:)
$script:UI    = @{}
$script:State = @{
    Ocupado = $false; Accion = ''; Handle = $null; PS = $null; Runspace = $null
    Salida = $null; Leidos = 0; ErrLeidos = 0; Codigo = $null
    Lista = @(); ListaOrigen = 'ninguna'; ListaFecha = ''
    Modelo = $null; ModeloEnCurso = $null; ModeloInstalado = $null
    CargaPS = $null; CargaRS = $null; CargaHandle = $null
}

# ============================================================================
# 3. UTILIDADES DE INTERFAZ
# ============================================================================
function Show-Msg {
    param([string]$Texto, [string]$Titulo = 'ResetEntuPC.com', [string]$Icono = 'Information', [string]$Botones = 'OK')
    return [Windows.Forms.MessageBox]::Show($script:UI.Form, $Texto, $Titulo, $Botones, $Icono)
}

function New-Etiqueta {
    param([string]$Texto, [int]$X, [int]$Y, [int]$W, [int]$H, [float]$Size = 9.5,
          [string]$Estilo = 'Regular', $Color = $script:C.Texto, [string]$Alinea = 'TopLeft')
    $l = New-Object Windows.Forms.Label
    $l.Text = $Texto
    $l.Location = New-Object Drawing.Point($X, $Y)
    $l.Size = New-Object Drawing.Size($W, $H)
    $l.AutoSize = $false
    $l.Font = New-Object Drawing.Font('Segoe UI', $Size, [Drawing.FontStyle]$Estilo)
    $l.ForeColor = $Color
    $l.BackColor = [Drawing.Color]::Transparent
    $l.TextAlign = $Alinea
    return $l
}

function New-Boton {
    param([string]$Texto, [int]$X, [int]$Y, [int]$W, [int]$H, $Color, $ColorHover, [float]$Size = 11)
    $b = New-Object Windows.Forms.Button
    $b.Text = $Texto
    $b.Location = New-Object Drawing.Point($X, $Y)
    $b.Size = New-Object Drawing.Size($W, $H)
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderSize = 0
    $b.FlatAppearance.MouseOverBackColor = $ColorHover
    $b.FlatAppearance.MouseDownBackColor = $ColorHover
    $b.BackColor = $Color
    $b.ForeColor = $script:C.Blanco
    $b.Font = New-Object Drawing.Font('Segoe UI Semibold', $Size)
    $b.Cursor = [Windows.Forms.Cursors]::Hand
    $b.UseVisualStyleBackColor = $false
    $b.Tag = $Color   # color "normal", para restaurarlo tras estar deshabilitado
    return $b
}

# Tarjeta blanca con borde fino
function New-Tarjeta {
    param([int]$X, [int]$Y, [int]$W, [int]$H)
    $p = New-Object Windows.Forms.Panel
    $p.Location = New-Object Drawing.Point($X, $Y)
    $p.Size = New-Object Drawing.Size($W, $H)
    $p.BackColor = $script:C.Blanco
    $p.Add_Paint({
        param($s, $e)
        $lapiz = New-Object Drawing.Pen($script:C.Borde)
        $e.Graphics.DrawRectangle($lapiz, 0, 0, $s.Width - 1, $s.Height - 1)
        $lapiz.Dispose()
    })
    return $p
}

function Add-Log {
    param([string]$Linea)
    if ([string]::IsNullOrWhiteSpace($Linea)) { return }
    $script:UI.Log.AppendText(($Linea.TrimEnd() + [Environment]::NewLine))
}

function Set-Estado {
    param([string]$Texto, [ValidateSet('Info', 'Ok', 'Error', 'Neutro')][string]$Tipo = 'Neutro')
    $color = switch ($Tipo) {
        'Info'  { $script:C.Acento }
        'Ok'    { $script:C.AzulOscuro }
        'Error' { $script:C.GrisOscuro }
        default { $script:C.Suave }
    }
    $script:UI.Estado.ForeColor = $color
    $script:UI.Estado.Text = $Texto
}

# Instalar y Reinstalar exigen modelo elegido Y la casilla de aceptación marcada.
# Desinstalar solo exige modelo elegido. Nada funciona mientras hay una operación en marcha.
function Update-Botones {
    $libre = -not $script:State.Ocupado
    $hayModelo = ($null -ne $script:State.Modelo)
    $acepto = [bool]$script:UI.ChkAcepto.Checked
    $reglas = @(
        @{ B = $script:UI.BtnInstalar;    Ok = ($libre -and $hayModelo -and $acepto) },
        @{ B = $script:UI.BtnReinstalar;  Ok = ($libre -and $hayModelo -and $acepto) },
        @{ B = $script:UI.BtnDesinstalar; Ok = ($libre -and $hayModelo) }
    )
    foreach ($r in $reglas) {
        $r.B.Enabled = $r.Ok
        $r.B.BackColor = if ($r.Ok) { $r.B.Tag } else { $script:C.Deshab }
    }
}

# Bloquea/desbloquea la ventana y muestra el cursor de espera + barra de progreso.
function Set-Ocupado {
    param([bool]$Ocupado)
    $script:State.Ocupado = $Ocupado
    $script:UI.Form.UseWaitCursor = $Ocupado
    $script:UI.Progreso.Visible = $Ocupado
    if ($script:TimerBarra) { if ($Ocupado) { $script:TimerBarra.Start() } else { $script:TimerBarra.Stop() } }
    $script:UI.TxtBuscar.Enabled = -not $Ocupado
    $script:UI.LstModelos.Enabled = -not $Ocupado
    $script:UI.BtnActualizar.Enabled = -not $Ocupado -and ($null -eq $script:State.CargaHandle)
    $script:UI.ChkAcepto.Enabled = -not $Ocupado
    Update-Botones
}

# Panel derecho: 'terminos' (políticas, siempre antes de instalar) o 'final' (activación).
function Show-Panel {
    param([ValidateSet('terminos', 'final')][string]$Cual, [string]$NombreModelo = '')
    if ($Cual -eq 'final') {
        $script:UI.Paso1.Text = "Paso 1: Abre el programa Reset Epson $NombreModelo que acaba de aparecer en tu escritorio."
    }
    $script:UI.PnlFinal.Visible = ($Cual -eq 'final')
    $script:UI.PnlTerminos.Visible = ($Cual -eq 'terminos')
}

# ============================================================================
# 4. LISTA DE MODELOS: descarga desde GitHub, copia guardada, búsqueda y selección
# ============================================================================
# "l3210" -> "L3210"; "artisan-1430" -> "Artisan-1430"
function ConvertTo-NombreModelo {
    param([string]$Id)
    return ($Id.ToUpperInvariant() -replace '^ARTISAN-', 'Artisan-')
}

# Compara sin distinguir mayúsculas ni guiones/espacios: "xp 231", "XP-231" y "xp231" coinciden.
function ConvertTo-Clave {
    param([string]$Texto)
    return ($Texto.ToLowerInvariant() -replace '[^a-z0-9]', '')
}

# Convierte el JSON en modelos VÁLIDOS. Se descarta todo lo que no cumpla los patrones o cuya URL
# no sea exactamente la del release del repositorio. Sin repetidos, ordenados por familia y número.
function ConvertTo-ListaModelos {
    param([string]$Json)
    $obj = $Json | ConvertFrom-Json
    $fecha = [string]$obj.actualizado
    if ($fecha -notmatch '^\d{4}-\d{2}-\d{2}$') { $fecha = '' }
    $vistos = @{}
    $lista = New-Object System.Collections.Generic.List[object]
    $descartados = 0
    foreach ($m in @($obj.modelos)) {
        $id = [string]$m.id; $tag = [string]$m.tag; $url = [string]$m.url
        $esperada = "$($script:BaseDescarga)/$tag/$id.1.0.0.nupkg"
        if ($id -cnotmatch $script:PatronId -or $tag -notmatch $script:PatronTag -or $url -cne $esperada -or $vistos.ContainsKey($id)) {
            $descartados++; continue
        }
        $vistos[$id] = $true
        $item = New-Object ModeloItem
        $item.Id = $id; $item.Tag = $tag; $item.Url = $url; $item.Modelo = ConvertTo-NombreModelo $id; $item.Nupkg = "$id.1.0.0.nupkg"
        $lista.Add($item)
    }
    $ordenada = @($lista | Sort-Object @{ Expression = { $_.Id -replace '\d+$', '' } }, @{ Expression = { [int]($_.Id -replace '^\D+', '') } })
    return @{ Modelos = $ordenada; Fecha = $fecha; Descartados = $descartados }
}

# Ordena por familia y número (L110, L120... ET-1810... XP-2205).
function Sort-Modelos {
    param($Lista)
    return @($Lista | Sort-Object @{ Expression = { $_.Id -replace '\d+$', '' } }, @{ Expression = { [int]($_.Id -replace '^\D+', '') } })
}

# Lee el diccionario interno y devuelve los modelos VÁLIDOS (una sola vez). Cada línea debe cumplir:
# id con patrón estricto, nombre coherente con el id, paquete = <id>.1.0.0.nupkg y URL exactamente
# https://github.com/resetentupc/ResetDownloads/releases/download/<etiqueta>/<paquete>. Lo demás se descarta.
function Get-Diccionario {
    if ($null -ne $script:DicItems) { return $script:DicItems }
    $lista = New-Object System.Collections.Generic.List[object]
    $vistos = @{}
    $descartados = 0
    foreach ($linea in ($script:DiccionarioTexto -split '\r?\n')) {
        if ([string]::IsNullOrWhiteSpace($linea)) { continue }
        $p = $linea.Trim() -split '\|'
        if ($p.Count -ne 3) { $descartados++; continue }
        $modelo = $p[0]; $nupkg = $p[1]; $url = $p[2]
        $id = $modelo.ToLowerInvariant()
        $patronUrl = '^' + [regex]::Escape($script:BaseDescarga) + '/(?<tag>[A-Za-z0-9][A-Za-z0-9._-]{0,60})/' + [regex]::Escape($nupkg) + '$'
        $m = [regex]::Match($url, $patronUrl)
        if ($id -cnotmatch $script:PatronId -or $modelo -cne (ConvertTo-NombreModelo $id) -or $nupkg -cne "$id.1.0.0.nupkg" -or -not $m.Success -or $vistos.ContainsKey($id)) {
            $descartados++; continue
        }
        $vistos[$id] = $true
        $item = New-Object ModeloItem
        $item.Modelo = $modelo; $item.Id = $id; $item.Nupkg = $nupkg; $item.Url = $url; $item.Tag = $m.Groups['tag'].Value
        $lista.Add($item)
    }
    $script:DicDescartados = $descartados
    $script:DicItems = Sort-Modelos $lista
    return $script:DicItems
}
# Rellena la lista visible según lo escrito en la caja de búsqueda.
function Update-Filtro {
    $ui = $script:UI
    $previo = $script:State.Modelo
    $q = ConvertTo-Clave $ui.TxtBuscar.Text
    $visibles = @($script:State.Lista | Where-Object { $q -eq '' -or (ConvertTo-Clave $_.Modelo).Contains($q) })

    $ui.LstModelos.BeginUpdate()
    $ui.LstModelos.Items.Clear()
    $ui.LstModelos.Items.AddRange([object[]]$visibles)
    $ui.LstModelos.EndUpdate()

    # Selección automática solo si hay UN resultado (o si el modelo anterior sigue visible).
    if ($visibles.Count -eq 1) { $ui.LstModelos.SelectedIndex = 0 }
    elseif ($previo -and ($visibles | Where-Object { $_.Id -eq $previo.Id })) { $ui.LstModelos.SelectedItem = ($visibles | Where-Object { $_.Id -eq $previo.Id } | Select-Object -First 1) }
    Update-Seleccion

    $total = $script:State.Lista.Count
    if ($total -gt 0) {
        $texto = if ($q -eq '') { "$total modelos" } else { "$($visibles.Count) de $total" }
        if ($script:State.ListaOrigen -ne 'red') { $texto += ' (sin conexión)' }
        $ui.LblContador.Text = $texto
    }
    else { $ui.LblContador.Text = '' }
}

# Al cambiar de modelo la casilla de aceptación se desmarca: la aceptación es por instalación.
function Update-Seleccion {
    $item = $script:UI.LstModelos.SelectedItem
    $idAntes = if ($script:State.Modelo) { $script:State.Modelo.Id } else { '' }
    $idAhora = if ($item) { $item.Id } else { '' }
    $script:State.Modelo = $item
    if ($idAntes -ne $idAhora -and $script:UI.ChkAcepto.Checked) { $script:UI.ChkAcepto.Checked = $false }
    if ($item) {
        $script:UI.LblModelo.Text = "Modelo elegido: $($item.Modelo)"
        $script:UI.LblModelo.ForeColor = $script:C.Marino
    }
    else {
        $script:UI.LblModelo.Text = 'Modelo elegido: (ninguno todavía)'
        $script:UI.LblModelo.ForeColor = $script:C.Suave
    }
    Update-Botones
}

# Construye la lista final = diccionario interno + modelos NUEVOS de la lista en línea (si la hay).
# Si un modelo está en las dos, MANDA EL DICCIONARIO INTERNO (su URL exacta no se sustituye nunca).
# Origen: 'red' (lista en línea recién descargada), 'cache' (última descarga guardada) o 'interna' (solo diccionario).
function Set-Modelos {
    param($Remoto, [ValidateSet('red', 'cache', 'interna')][string]$Origen)
    $dic = @(Get-Diccionario)
    $porId = @{}
    $mezcla = New-Object System.Collections.Generic.List[object]
    foreach ($d in $dic) { $porId[$d.Id] = $d; $mezcla.Add($d) }
    $nuevos = 0; $conflictos = 0
    if ($Remoto) {
        foreach ($r in @($Remoto.Modelos)) {
            if ($porId.ContainsKey($r.Id)) { if ($porId[$r.Id].Url -cne $r.Url) { $conflictos++ } }
            else { $mezcla.Add($r); $nuevos++ }
        }
    }
    if ($conflictos -gt 0) { Add-Log "[aviso] $conflictos modelo(s) de la lista en línea traen otra URL: se usa la del diccionario interno." }
    $script:State.Lista = @(Sort-Modelos $mezcla)
    $script:State.ListaOrigen = $Origen
    $script:State.ListaNuevos = $nuevos
    $script:State.ListaFecha = if ($Remoto) { $Remoto.Fecha } else { '' }
    $script:UI.BtnActualizar.Enabled = -not $script:State.Ocupado
    $n = $script:State.Lista.Count
    $fecha = if ($script:State.ListaFecha) { " ($($script:State.ListaFecha))" } else { '' }
    if ($n -eq 0) { Set-Estado 'No hay ningún modelo disponible. Pulsa «Actualizar lista de modelos» para reintentar.' 'Error' }
    else {
        switch ($Origen) {
            'red' {
                $extra = if ($nuevos -gt 0) { ", $nuevos nuevos" } else { '' }
                Set-Estado "Lista actualizada$($fecha): $n modelos$extra. Busca el tuyo y elígelo." 'Ok'
            }
            'cache' { Set-Estado "Sin conexión: usando la lista interna y la última descarga$($fecha). Pulsa «Actualizar lista de modelos» para reintentar." 'Info' }
            default { Set-Estado "Sin conexión con la lista en línea: usando la lista interna ($n modelos). Pulsa «Actualizar lista de modelos» para buscar modelos nuevos." 'Info' }
        }
    }
    if ($n -gt 0 -and $script:ModeloInicial) { $script:UI.TxtBuscar.Text = $script:ModeloInicial; $script:ModeloInicial = '' }
    Update-Filtro
}
# Sin conexión (o lista inservible): se usa la última copia guardada (si existe y es válida) junto al diccionario interno.
function Use-CopiaGuardada {
    param([string]$Motivo)
    if ($Motivo) { Add-Log "[aviso] $Motivo" }
    $res = $null
    try {
        if (Test-Path -LiteralPath $script:CacheFile) {
            $res = ConvertTo-ListaModelos ([IO.File]::ReadAllText($script:CacheFile))
        }
    }
    catch { Add-Log "[aviso] La copia guardada no se pudo leer: $($_.Exception.Message)" }
    if ($res -and $res.Modelos.Count -gt 0) { Set-Modelos $res 'cache'; return }
    Set-Modelos $null 'interna'
}

# Guarda la lista recién descargada (ya validada) para el próximo arranque sin conexión.
function Save-CopiaGuardada {
    param([string]$Json)
    try {
        if (-not (Test-Path -LiteralPath $script:CacheDir)) { [void](New-Item -ItemType Directory -Path $script:CacheDir -Force) }
        [IO.File]::WriteAllText($script:CacheFile, $Json, (New-Object System.Text.UTF8Encoding($false)))
    }
    catch { Add-Log "[aviso] No se pudo guardar la copia local: $($_.Exception.Message)" }
}

# Descarga la lista en segundo plano (la ventana sigue viva aunque la red vaya lenta).
function Start-CargaModelos {
    $s = $script:State
    if ($s.CargaHandle -or $s.Ocupado) { return }
    $script:UI.BtnActualizar.Enabled = $false
    Set-Estado 'Descargando la lista de modelos...' 'Info'
    if ($script:Prueba) { Set-Modelos @{ Modelos = @(); Fecha = '' } 'red'; return }
    try {
        $rs = [runspacefactory]::CreateRunspace(); $rs.Open()
        $rs.SessionStateProxy.SetVariable('url', [string]$script:ListaUrl)
        $ps = [powershell]::Create(); $ps.Runspace = $rs
        [void]$ps.AddScript($script:GuionLista)
        $s.CargaRS = $rs; $s.CargaPS = $ps
        $s.CargaHandle = $ps.BeginInvoke()
        $script:TimerLista.Start()
    }
    catch { Use-CopiaGuardada ('No se pudo iniciar la descarga de la lista: ' + $_.Exception.Message) }
}

function Update-CargaModelos {
    $s = $script:State
    if ($null -eq $s.CargaHandle -or -not $s.CargaHandle.IsCompleted) { return }
    $script:TimerLista.Stop()
    $salida = @(); $fallo = $null
    try { $salida = @($s.CargaPS.EndInvoke($s.CargaHandle)) }
    catch { $fallo = if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message } }
    $s.CargaPS.Dispose(); $s.CargaRS.Close(); $s.CargaRS.Dispose()
    $s.CargaPS = $null; $s.CargaRS = $null; $s.CargaHandle = $null
    if ($fallo) { Use-CopiaGuardada "No se pudo descargar la lista: $fallo"; return }

    $json = (@($salida | ForEach-Object { [string]$_ }) -join "`n")
    try {
        $res = ConvertTo-ListaModelos $json
        if ($res.Modelos.Count -eq 0) { throw 'la lista descargada no contiene ningún modelo válido' }
    }
    catch { Use-CopiaGuardada "La lista descargada no es válida: $($_.Exception.Message)"; return }
    if ($res.Descartados -gt 0) { Add-Log "[aviso] Se descartaron $($res.Descartados) entradas que no cumplen las reglas de seguridad." }
    Save-CopiaGuardada $json
    Set-Modelos $res 'red'
}

# ============================================================================
# 5. EJECUCIÓN EN SEGUNDO PLANO (runspace + temporizador; la ventana no se congela)
# ============================================================================
function Start-Accion {
    param([ValidateSet('Instalar', 'Reinstalar', 'Desinstalar')][string]$Accion)
    $s = $script:State
    if ($s.Ocupado) { return }
    $item = $s.Modelo
    if ($null -eq $item) {
        [void](Show-Msg -Icono 'Information' -Texto 'Primero busca tu modelo y haz clic en él en la lista.')
        return
    }
    # Instalar/Reinstalar: la aceptación de las políticas es obligatoria (defensa extra al bloqueo del botón).
    if ($Accion -ne 'Desinstalar' -and -not $script:UI.ChkAcepto.Checked) {
        [void](Show-Msg -Icono 'Information' -Texto 'Para instalar debes leer las políticas y marcar la casilla de confirmación.')
        return
    }
    # Defensa extra: aunque ya se validó al cargar, se vuelve a comprobar justo antes de ejecutar.
    if ($item.Id -cnotmatch $script:PatronId -or $item.Tag -notmatch $script:PatronTag -or $item.Nupkg -cne "$($item.Id).1.0.0.nupkg" -or $item.Url -cne "$($script:BaseDescarga)/$($item.Tag)/$($item.Nupkg)") {
        [void](Show-Msg -Icono 'Error' -Texto 'El modelo elegido no es válido.')
        return
    }
    if (-not $script:Prueba -and -not (Get-Command choco -ErrorAction SilentlyContinue)) {
        [void](Show-Msg -Icono 'Warning' -Texto ("Chocolatey no está instalado en este equipo.`r`n`r`n" +
            "Instálalo desde https://chocolatey.org/install (PowerShell como administrador) y vuelve a abrir este programa."))
        return
    }

    $m = $item.Modelo
    $mensajes = @{
        Instalar    = "Instalando Reset Epson $m... puede tardar unos minutos."
        Reinstalar  = "Reinstalando Reset Epson $m... puede tardar unos minutos."
        Desinstalar = "Desinstalando Reset Epson $m..."
    }
    $script:UI.Log.Clear()
    Show-Panel 'terminos'
    Set-Ocupado $true
    Set-Estado $mensajes[$Accion] 'Info'
    Add-Log ("> {0} {1} ({2})" -f $Accion, $m, (Get-Date -Format 'HH:mm:ss'))

    $guion = $script:Preambulo + "`r`n" + $script:Comandos[$Accion] + "`r`n" + '"__EXIT__:$LASTEXITCODE"'
    try {
        $rs = [runspacefactory]::CreateRunspace()
        $rs.Open()
        # El id, la etiqueta, la URL y el paquete (ya validados) viajan como VARIABLES, no pegados en el comando.
        $rs.SessionStateProxy.SetVariable('id', [string]$item.Id)
        $rs.SessionStateProxy.SetVariable('tag', [string]$item.Tag)
        $rs.SessionStateProxy.SetVariable('url', [string]$item.Url)
        $rs.SessionStateProxy.SetVariable('nupkg', [string]$item.Nupkg)
        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        [void]$ps.AddScript($guion)
        $entrada = New-Object 'System.Management.Automation.PSDataCollection[psobject]'
        $entrada.Complete()
        $salida = New-Object 'System.Management.Automation.PSDataCollection[psobject]'

        $s.Accion = $Accion; $s.PS = $ps; $s.Runspace = $rs; $s.Salida = $salida
        $s.Leidos = 0; $s.ErrLeidos = 0; $s.Codigo = $null
        $s.ModeloEnCurso = $item
        $s.Handle = $ps.BeginInvoke($entrada, $salida)
    }
    catch {
        Set-Ocupado $false
        Set-Estado 'No se pudo iniciar la operación.' 'Error'
        Add-Log $_.Exception.Message
        return
    }
    $script:Timer.Start()
}

# Lee lo que va produciendo el segundo plano y detecta cuándo termina.
function Update-Progreso {
    $s = $script:State
    if ($null -eq $s.Handle) { return }
    $terminado = $s.Handle.IsCompleted   # se consulta ANTES de leer, para no perder líneas finales

    while ($s.Leidos -lt $s.Salida.Count) {
        $linea = [string]$s.Salida[$s.Leidos]
        $s.Leidos++
        if ($linea -match '^__EXIT__:(.*)$') { $s.Codigo = $Matches[1].Trim() } else { Add-Log $linea }
    }
    while ($s.ErrLeidos -lt $s.PS.Streams.Error.Count) {
        Add-Log ('[error] ' + $s.PS.Streams.Error[$s.ErrLeidos])
        $s.ErrLeidos++
    }

    if ($terminado) { Complete-Accion }
}

function Complete-Accion {
    $script:Timer.Stop()
    $s = $script:State
    $fallo = $null
    try { [void]$s.PS.EndInvoke($s.Handle) }
    catch { $fallo = $_.Exception.Message }
    if ($fallo -and $s.ErrLeidos -eq 0) { Add-Log ('[error] ' + $fallo) }

    $s.PS.Dispose(); $s.Runspace.Close(); $s.Runspace.Dispose()
    $s.PS = $null; $s.Runspace = $null; $s.Handle = $null
    Set-Ocupado $false
    # Cada instalación exige una aceptación nueva.
    if ($s.Accion -ne 'Desinstalar') { $script:UI.ChkAcepto.Checked = $false }

    $m = $s.ModeloEnCurso.Modelo
    $ok = (-not $fallo) -and ($script:CodigosOk -contains [string]$s.Codigo)
    if (-not $ok) {
        $detalle = if ($s.Codigo) { "código $($s.Codigo)" } else { 'error de descarga o de ejecución' }
        Set-Estado "La operación no terminó bien ($detalle). Revisa el registro." 'Error'
        if (-not $script:Prueba) {
            [void](Show-Msg -Icono 'Error' -Texto "La operación no se completó ($detalle).`r`n`r`nRevisa el registro de la ventana o escríbenos por WhatsApp.")
        }
        return
    }

    if ($s.Accion -eq 'Desinstalar') {
        Set-Estado "Reset Epson $m se desinstaló correctamente." 'Ok'
        return
    }

    # Instalación o reinstalación correcta: se muestra el "Paso final" (activación).
    $s.ModeloInstalado = $s.ModeloEnCurso
    Set-Estado '¡Instalación completada! Sigue el "Paso final" de la derecha.' 'Ok'
    Show-Panel 'final' $m
    if (-not $script:Prueba) {
        [void](Show-Msg -Icono 'Information' -Titulo 'Instalación completada' -Texto (
            "¡Reset Epson $m se instaló correctamente!`r`n`r`n" +
            "Solo falta la activación: sigue el ""Paso final"" que aparece a la derecha de la ventana."))
    }
    $script:UI.TxtPcId.Focus()
}

# ============================================================================
# 6. CONTACTO: un único botón, WhatsApp (usa el modelo que se acaba de instalar)
# ============================================================================
function Get-PcId { return ([string]$script:UI.TxtPcId.Text).Trim() }

# El PC ID es OPCIONAL: muchos clientes no saben cómo obtenerlo, así que sin ID se envía
# otro texto pidiendo ayuda (sin avisos ni pasos extra).
function Get-Mensaje {
    $pc = Get-PcId
    $m = if ($script:State.ModeloInstalado) { $script:State.ModeloInstalado.Modelo } else { '' }
    if ($pc) { return "Hola, acabo de instalar el reset $m. Mi PC ID es: $pc" }
    return "Hola, acabo de instalar el reset $m pero no sé cómo obtener mi PC ID. ¿Me pueden ayudar?"
}

function Open-Enlace {
    param([string]$Direccion)
    try { Start-Process -FilePath $Direccion }
    catch { [void](Show-Msg -Icono 'Warning' -Texto "No se pudo abrir el enlace:`r`n$Direccion") }
}

function Open-WhatsApp {
    Open-Enlace ("https://wa.me/{0}?text={1}" -f $script:WhatsAppNumero, [uri]::EscapeDataString((Get-Mensaje)))
}

# ============================================================================
# 7. CONSTRUCCIÓN DE LA VENTANA
# ============================================================================
function New-Ventana {
    $C = $script:C
    $ui = $script:UI

    $form = New-Object Windows.Forms.Form
    $form.Text = 'Instalador - ResetEntuPC.com'
    if ($script:Prueba) { $form.Text += '  [MODO PRUEBA]' }
    $form.AutoScaleDimensions = New-Object Drawing.SizeF(96, 96)
    $form.AutoScaleMode = 'Dpi'
    $form.ClientSize = New-Object Drawing.Size(900, 598)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedSingle'
    $form.MaximizeBox = $false
    $form.BackColor = $C.Fondo
    $form.Font = New-Object Drawing.Font('Segoe UI', 9.5)
    $form.Icon = [Drawing.SystemIcons]::Shield
    $ui.Form = $form

    $tips = New-Object Windows.Forms.ToolTip

    # ---- Cabecera ----
    $cab = New-Object Windows.Forms.Panel
    $cab.Dock = 'Top'; $cab.Height = 84; $cab.BackColor = $C.Marino
    $cab.Controls.Add((New-Etiqueta 'ResetEntuPC.com' 24 10 400 36 20 'Bold' $C.Blanco))
    $cab.Controls.Add((New-Etiqueta 'Instalador de Reset Epson · Solución al Error de Almohadillas' 26 48 560 24 10.5 'Regular' (New-Color '#9CC3FF')))
    $cab.Controls.Add((New-Etiqueta ('Versión ' + $script:Version) 660 50 216 22 9 'Regular' (New-Color '#9CC3FF') 'MiddleRight'))
    $lineaCab = New-Object Windows.Forms.Panel   # línea divisoria naranja bajo la cabecera
    $lineaCab.Dock = 'Bottom'; $lineaCab.Height = 3; $lineaCab.BackColor = $C.Naranja
    $cab.Controls.Add($lineaCab)
    $form.Controls.Add($cab)

    # ---- Columna izquierda: modelo, aceptación y acciones ----
    $form.Controls.Add((New-Etiqueta '1. BUSCA TU MODELO' 20 100 175 20 8.5 'Bold' $C.Suave))
    $ui.LblContador = New-Etiqueta '' 195 100 185 20 8.5 'Regular' $C.Suave 'TopRight'
    $form.Controls.Add($ui.LblContador)

    $ui.TxtBuscar = New-Object Windows.Forms.TextBox
    $ui.TxtBuscar.Location = New-Object Drawing.Point(20, 122)
    $ui.TxtBuscar.Size = New-Object Drawing.Size(360, 28)
    $ui.TxtBuscar.Font = New-Object Drawing.Font('Segoe UI', 11)
    $form.Controls.Add($ui.TxtBuscar)

    $ui.LstModelos = New-Object Windows.Forms.ListBox
    $ui.LstModelos.Location = New-Object Drawing.Point(20, 154)
    $ui.LstModelos.Size = New-Object Drawing.Size(360, 92)
    $ui.LstModelos.Font = New-Object Drawing.Font('Segoe UI', 10.5)
    $ui.LstModelos.IntegralHeight = $false
    $ui.LstModelos.BorderStyle = 'FixedSingle'
    $form.Controls.Add($ui.LstModelos)

    $ui.BtnActualizar = New-Boton 'Actualizar lista de modelos' 20 250 360 30 $C.AzulClaro $C.AzulClaroHov 10
    $tips.SetToolTip($ui.BtnActualizar, 'Descarga de nuevo la lista de modelos disponibles (por si se agregó uno nuevo).')
    $ui.BtnActualizar.Add_Click({ Start-CargaModelos })
    $form.Controls.Add($ui.BtnActualizar)

    $ui.LblModelo = New-Etiqueta '' 20 284 360 22 10 'Bold' $C.Suave 'MiddleLeft'
    $form.Controls.Add($ui.LblModelo)

    # Casilla obligatoria, JUSTO ENCIMA de los botones. Sin marcarla, Instalar/Reinstalar no se activan.
    $ui.ChkAcepto = New-Object Windows.Forms.CheckBox
    $ui.ChkAcepto.Text = $script:TextoAceptacion
    $ui.ChkAcepto.Location = New-Object Drawing.Point(20, 308)
    $ui.ChkAcepto.Size = New-Object Drawing.Size(360, 60)
    $ui.ChkAcepto.AutoSize = $false
    $ui.ChkAcepto.CheckAlign = 'TopLeft'
    $ui.ChkAcepto.TextAlign = 'TopLeft'
    $ui.ChkAcepto.Checked = $false
    $ui.ChkAcepto.Font = New-Object Drawing.Font('Segoe UI', 8.75)
    $ui.ChkAcepto.ForeColor = $C.Texto
    $ui.ChkAcepto.Cursor = [Windows.Forms.Cursors]::Hand
    $ui.ChkAcepto.Add_CheckedChanged({ Update-Botones })
    $form.Controls.Add($ui.ChkAcepto)

    $ui.BtnInstalar    = New-Boton 'Instalar'    20  370 116 40 $C.Rojo $C.RojoHov 10.5
    $ui.BtnReinstalar  = New-Boton 'Reinstalar'  142 370 116 40 $C.AzulOscuro $C.AzulOscuroHov 10.5
    $ui.BtnDesinstalar = New-Boton 'Desinstalar' 264 370 116 40 $C.GrisAzul $C.GrisAzulHov 10.5
    $tips.SetToolTip($ui.BtnInstalar,    'Descarga e instala el modelo elegido (requiere marcar la casilla de confirmación).')
    $tips.SetToolTip($ui.BtnReinstalar,  'Vuelve a instalar el modelo elegido (requiere marcar la casilla de confirmación).')
    $tips.SetToolTip($ui.BtnDesinstalar, 'Elimina el modelo elegido de este equipo.')
    $ui.BtnInstalar.Add_Click({ Start-Accion 'Instalar' })
    $ui.BtnReinstalar.Add_Click({ Start-Accion 'Reinstalar' })
    $ui.BtnDesinstalar.Add_Click({ Start-Accion 'Desinstalar' })
    $form.Controls.AddRange(@($ui.BtnInstalar, $ui.BtnReinstalar, $ui.BtnDesinstalar))

    $ui.Estado = New-Etiqueta 'Preparando...' 20 414 360 36 9.5 'Bold' $C.Suave 'MiddleLeft'
    $form.Controls.Add($ui.Estado)

    # Barra de progreso propia (azul): la de Windows se dibuja en verde, color reservado para WhatsApp.
    $ui.Progreso = New-Object Windows.Forms.Panel
    $ui.Progreso.Location = New-Object Drawing.Point(20, 452)
    $ui.Progreso.Size = New-Object Drawing.Size(360, 6)
    $ui.Progreso.BackColor = $C.Borde
    $ui.Progreso.Visible = $false
    $ui.ProgresoBarra = New-Object Windows.Forms.Panel
    $ui.ProgresoBarra.Location = New-Object Drawing.Point(0, 0)
    $ui.ProgresoBarra.Size = New-Object Drawing.Size(90, 6)
    $ui.ProgresoBarra.BackColor = $C.AzulClaro
    $ui.Progreso.Controls.Add($ui.ProgresoBarra)
    $form.Controls.Add($ui.Progreso)

    $form.Controls.Add((New-Etiqueta 'REGISTRO' 20 460 360 16 8.5 'Bold' $C.Suave))
    $ui.Log = New-Object Windows.Forms.TextBox
    $ui.Log.Location = New-Object Drawing.Point(20, 478)
    $ui.Log.Size = New-Object Drawing.Size(360, 64)
    $ui.Log.Multiline = $true
    $ui.Log.ReadOnly = $true
    $ui.Log.ScrollBars = 'Vertical'
    $ui.Log.BorderStyle = 'None'
    $ui.Log.BackColor = $C.LogFondo
    $ui.Log.ForeColor = $C.LogTexto
    $ui.Log.Font = New-Object Drawing.Font('Consolas', 8.5)
    $form.Controls.Add($ui.Log)

    # Eventos de búsqueda y selección
    $ui.TxtBuscar.Add_TextChanged({ Update-Filtro })
    $ui.LstModelos.Add_SelectedIndexChanged({ Update-Seleccion })
    $ui.TxtBuscar.Add_KeyDown({
        param($s, $e)
        # Flecha abajo / Intro: pasa a la lista (y elige el primero si aún no hay ninguno).
        if ($e.KeyCode -eq 'Down' -or $e.KeyCode -eq 'Return') {
            $e.SuppressKeyPress = $true
            if ($script:UI.LstModelos.Items.Count -gt 0) {
                if ($script:UI.LstModelos.SelectedIndex -lt 0) { $script:UI.LstModelos.SelectedIndex = 0 }
                $script:UI.LstModelos.Focus()
            }
        }
    })

    # ---- Columna derecha, estado A: POLÍTICAS DEL SERVICIO (visibles antes de instalar) ----
    $terminos = New-Tarjeta 400 104 480 438
    $franjaA = New-Object Windows.Forms.Panel
    $franjaA.Location = New-Object Drawing.Point(0, 0); $franjaA.Size = New-Object Drawing.Size(480, 6); $franjaA.BackColor = $C.Naranja
    $terminos.Controls.Add($franjaA)
    $terminos.Controls.Add((New-Etiqueta 'Políticas del servicio · léelas antes de instalar' 16 14 448 26 12 'Bold' $C.Marino))

    $rtb = New-Object Windows.Forms.RichTextBox
    $rtb.Location = New-Object Drawing.Point(16, 46)
    $rtb.Size = New-Object Drawing.Size(448, 298)
    $rtb.ReadOnly = $true
    $rtb.BorderStyle = 'None'
    $rtb.BackColor = $C.Blanco
    $rtb.ScrollBars = 'Vertical'
    $rtb.DetectUrls = $false
    $fTitulo = New-Object Drawing.Font('Segoe UI Semibold', 10.5)
    $fTexto = New-Object Drawing.Font('Segoe UI', 10)
    $n = 0
    foreach ($p in $script:Politicas) {
        $n++
        $rtb.SelectionStart = $rtb.TextLength; $rtb.SelectionLength = 0
        $rtb.SelectionFont = $fTitulo; $rtb.SelectionColor = $C.Marino
        $rtb.AppendText("$n. $($p.Titulo)`n")
        $rtb.SelectionStart = $rtb.TextLength; $rtb.SelectionLength = 0
        $rtb.SelectionFont = $fTexto; $rtb.SelectionColor = $C.Texto
        $rtb.AppendText($p.Texto + "`n`n")
    }
    $rtb.SelectionStart = 0; $rtb.SelectionLength = 0
    $terminos.Controls.Add($rtb)
    $ui.RtbPoliticas = $rtb

    # Aviso sobre otros antivirus (solo información: el programa no toca la configuración de seguridad).
    $aviso = New-Object Windows.Forms.Panel
    $aviso.Location = New-Object Drawing.Point(16, 352); $aviso.Size = New-Object Drawing.Size(448, 76)
    $aviso.BackColor = $C.AvisoFondo
    $lineaAviso = New-Object Windows.Forms.Panel   # borde naranja a la izquierda del aviso (una línea, no un relleno)
    $lineaAviso.Dock = 'Left'; $lineaAviso.Width = 4; $lineaAviso.BackColor = $C.Naranja
    $aviso.Controls.Add($lineaAviso)
    $aviso.Controls.Add((New-Etiqueta ('Aviso: ' + $script:AvisoAntivirus) 12 6 424 64 9.5 'Regular' $C.Texto 'MiddleLeft'))
    $terminos.Controls.Add($aviso)
    $ui.PnlTerminos = $terminos
    $form.Controls.Add($terminos)

    # ---- Columna derecha, estado B: "Paso final" (activación) ----
    $final = New-Tarjeta 400 104 480 438
    $final.Visible = $false
    $franja = New-Object Windows.Forms.Panel
    $franja.Location = New-Object Drawing.Point(0, 0); $franja.Size = New-Object Drawing.Size(480, 6); $franja.BackColor = $C.Naranja
    $final.Controls.Add($franja)
    $final.Controls.Add((New-Etiqueta '¡Instalación completada!' 20 16 440 28 14 'Bold' $C.AzulOscuro))
    $final.Controls.Add((New-Etiqueta 'Paso final: activa tu licencia' 20 44 440 22 10.5 'Bold' $C.Marino))

    $pasos = @(
        @{ N = '1'; Y = 78;  H = 46; T = 'Paso 1: Abre el programa Reset Epson que acaba de aparecer en tu escritorio.' },
        @{ N = '2'; Y = 128; H = 46; T = 'Paso 2: Copia el PC ID que te muestra la ventana del programa.' },
        @{ N = '3'; Y = 178; H = 64; T = 'Paso 3: Haz clic en el botón de WhatsApp a continuación para enviarnos tu PC ID, realizar el pago y recibir tu KEY de activación en minutos.' }
    )
    foreach ($p in $pasos) {
        $circulo = New-Etiqueta $p.N 20 ($p.Y + 2) 26 26 10 'Bold' $C.Blanco 'MiddleCenter'
        $circulo.BackColor = $C.Acento
        $final.Controls.Add($circulo)
        $texto = New-Etiqueta $p.T 56 $p.Y 404 $p.H 10 'Regular' $C.Texto
        if ($p.N -eq '1') { $ui.Paso1 = $texto }   # su texto lleva el nombre del modelo y se actualiza al instalar
        $final.Controls.Add($texto)
    }

    $final.Controls.Add((New-Etiqueta 'Tu PC ID (opcional: si no lo tienes, escríbenos igual):' 20 254 440 20 9 'Regular' $C.Suave))
    $ui.TxtPcId = New-Object Windows.Forms.TextBox
    $ui.TxtPcId.Location = New-Object Drawing.Point(20, 276)
    $ui.TxtPcId.Size = New-Object Drawing.Size(440, 28)
    $ui.TxtPcId.Font = New-Object Drawing.Font('Consolas', 11)
    $final.Controls.Add($ui.TxtPcId)

    # Único botón de contacto.
    $btnWa = New-Boton ('Escribir por WhatsApp (' + $script:WhatsAppVisible + ')') 20 322 440 50 $C.WaVerde $C.WaVerdeHov 11.5
    $btnWa.Add_Click({ Open-WhatsApp })
    $tips.SetToolTip($btnWa, 'Abre WhatsApp con el mensaje ya escrito (con tu PC ID si lo pegaste; si no, pidiendo ayuda).')
    $final.Controls.Add($btnWa)

    $enlacePol = New-Object Windows.Forms.LinkLabel
    $enlacePol.Text = 'Volver a ver las políticas del servicio'
    $enlacePol.Location = New-Object Drawing.Point(20, 402); $enlacePol.Size = New-Object Drawing.Size(300, 22)
    $enlacePol.Font = New-Object Drawing.Font('Segoe UI', 9)
    $enlacePol.LinkColor = $C.Acento
    $enlacePol.Cursor = [Windows.Forms.Cursors]::Hand
    $enlacePol.Add_LinkClicked({ Show-Panel 'terminos' })
    $final.Controls.Add($enlacePol)
    $ui.PnlFinal = $final
    $form.Controls.Add($final)

    # ---- Pie de página: contacto de la empresa, siempre visible ----
    $pie = New-Object Windows.Forms.Panel
    $pie.Dock = 'Bottom'; $pie.Height = 42; $pie.BackColor = $C.Marino
    $lineaPie = New-Object Windows.Forms.Panel   # línea divisoria naranja sobre el pie
    $lineaPie.Dock = 'Top'; $lineaPie.Height = 2; $lineaPie.BackColor = $C.Naranja
    $tabla = New-Object Windows.Forms.TableLayoutPanel
    $tabla.Dock = 'Fill'; $tabla.BackColor = $C.Marino; $tabla.ColumnCount = 3; $tabla.RowCount = 1
    foreach ($k in 1..3) { [void]$tabla.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 33.33))) }
    $datosPie = @(
        @{ Rotulo = 'Sitio web';           Valor = 'resetentupc.com' },
        @{ Rotulo = 'Correo';              Valor = 'resetentupc@gmail.com' },
        @{ Rotulo = 'WhatsApp';            Valor = $script:WhatsAppVisible }
    )
    $columna = 0
    foreach ($dato in $datosPie) {
        $etiquetaPie = New-Object Windows.Forms.Label
        $etiquetaPie.Dock = 'Fill'; $etiquetaPie.TextAlign = 'MiddleCenter'; $etiquetaPie.AutoSize = $false
        $etiquetaPie.Font = New-Object Drawing.Font('Segoe UI Semibold', 9.5)
        $etiquetaPie.ForeColor = $C.Blanco
        $etiquetaPie.Text = $dato.Rotulo + ':  ' + $dato.Valor
        $tabla.Controls.Add($etiquetaPie, $columna, 0)
        $columna++
    }
    $pie.Controls.Add($tabla)
    $pie.Controls.Add($lineaPie)
    $form.Controls.Add($pie)

    # ---- Temporizadores que revisan el segundo plano ----
    $script:Timer = New-Object Windows.Forms.Timer
    $script:Timer.Interval = 300
    $script:Timer.Add_Tick({ Update-Progreso })
    # Animación de la barra de progreso (un tramo azul que recorre la barra).
    $script:TimerBarra = New-Object Windows.Forms.Timer
    $script:TimerBarra.Interval = 25
    $script:TimerBarra.Add_Tick({
        $barra = $script:UI.ProgresoBarra
        $x = $barra.Left + 8
        if ($x -gt $script:UI.Progreso.Width) { $x = -$barra.Width }
        $barra.Left = $x
    })
    $script:TimerLista = New-Object Windows.Forms.Timer
    $script:TimerLista.Interval = 300
    $script:TimerLista.Add_Tick({ Update-CargaModelos })

    # Al mostrarse la ventana: texto de ayuda en la búsqueda y descarga de la lista de modelos.
    $form.Add_Shown({
        try { [void][Win32.Cue]::SendMessage($script:UI.TxtBuscar.Handle, 0x1501, [IntPtr]1, 'Escribe tu modelo (ej. L3210 o XP-231)') } catch { }
        Update-Seleccion
        Start-CargaModelos
        $script:UI.TxtBuscar.Focus()
    })

    # No se puede cerrar mientras choco está trabajando (evita instalaciones a medias).
    $form.Add_FormClosing({
        param($s, $e)
        if ($script:State.Ocupado) {
            $e.Cancel = $true
            [void](Show-Msg -Texto 'Hay una operación en curso. Espera a que termine para cerrar la ventana.')
        }
    })
    $form.Add_FormClosed({
        $script:Timer.Stop(); $script:Timer.Dispose()
        $script:TimerLista.Stop(); $script:TimerLista.Dispose()
        $script:TimerBarra.Stop(); $script:TimerBarra.Dispose()
        if ($script:State.CargaPS) { try { $script:State.CargaPS.Stop() } catch { } }
    })

    return $form
}

function Show-Ventana {
    $form = New-Ventana
    [void]$form.ShowDialog()
}

# ============================================================================
# 8. ARRANQUE  (no se ejecuta si el archivo se carga con "punto" para pruebas)
# ============================================================================
if ($MyInvocation.InvocationName -ne '.') {
    Show-Ventana
}
