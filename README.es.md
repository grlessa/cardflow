[Português](README.md) · [English](README.en.md) · **Español**

# Cardflow

Copia tus tarjetas de cámara sin miedo a perder una sola toma.

Conectas la tarjeta y el disco donde quieres guardarla. Cardflow copia todo, verifica archivo por
archivo y solo te avisa de que ya puedes formatear la tarjeta cuando tiene la certeza de que cada
foto y cada video llegó intacto. Si quieres, copia a dos lugares a la vez: un disco y un backup.

Lo hice para quien graba cultos, eventos, conciertos o bodas y necesita vaciar la tarjeta con
seguridad, sin andar arrastrando carpetas a mano y rezando para que nada se corrompa en el camino.

## Qué hace

- Copia a un disco y, si quieres, a un backup al mismo tiempo.
- Después de copiar, verifica cada archivo. Si alguno no coincide, te avisa en rojo para que no
  formatees la tarjeta.
- Cuando todo está bien, te da luz verde. Ahí puedes formatear tranquilo.
- Organiza las carpetas como tú lo configures: por fecha, evento, cámara o tipo de medio.
- Si lo ejecutas de nuevo en la misma tarjeta, se salta lo que ya copió en vez de duplicar.
- Copia formatos de cine (RED, Blackmagic, Sony, ARRI) sin tocar la estructura de carpetas que esas
  cámaras necesitan.

## Instalar

1. Descarga Cardflow.dmg desde la página de [Releases](../../releases).
2. Abre el archivo y arrastra Cardflow a la carpeta Aplicaciones.
3. La primera vez que leas una tarjeta, el Mac pregunta una sola vez si la app puede acceder a los
   discos. Haz clic en Permitir. No vuelve a preguntar con cada tarjeta.

La app está firmada y reconocida por Apple, así que abre con normalidad, sin ese aviso de
"desarrollador no identificado".

Si aun así el Mac no la deja abrir (pasa en algunos casos), haz clic derecho sobre Cardflow y elige
Abrir. Ahí aparece la opción de abrirla de todos modos, y no vuelve a preguntar.

## Cómo usar

1. Conecta la tarjeta y el disco donde quieres guardar.
2. Elige el disco de destino, y el de backup si vas a usar uno.
3. Haz clic en Iniciar y espera.
4. Cuando aparezca el verde, puedes formatear la tarjeta con seguridad.

## Actualizaciones

Cuando abres la app, le da un vistazo aquí en GitHub para ver si salió una versión nueva. Si salió,
aparece un aviso pequeño con un botón de descarga. Solo tienes que tomar el DMG nuevo e instalarlo
encima.

## Privacidad

Cardflow trabaja sin conexión. La única vez que usa internet es en ese vistazo para ver si hay
versión nueva, y aun así solo lee el número de versión. Tus archivos nunca salen de tu computadora,
y no hay registro ni rastreo de ningún tipo.

## Para quien quiere los detalles técnicos

App nativa de macOS hecha en Swift y SwiftUI. El motor (`OffloadKit`) es Swift puro y sin
dependencias externas; la app usa Sparkle solo para la actualización in-app.

### Cómo funciona la verificación

No es un copiar y pegar común. Para cada archivo, Cardflow calcula un hash xxHash64 del origen y de
lo que se grabó en cada destino, y solo lo marca como verificado cuando los dos coinciden. Antes de
comparar, fuerza un fsync para garantizar que los bytes salieron del caché y llegaron de verdad al
disco. Si la verificación falla, el archivo corrupto se borra y la interfaz retiene la luz verde. La
tarjeta nunca aparece como segura sin esa prueba.

Otras garantías del motor:

- No sobrescribe. Ejecutarlo de nuevo se salta lo que ya está ahí (mismo hash) y separa los archivos
  con el mismo nombre pero contenido distinto en vez de pasarles por encima.
- Preserva el cine. RED (.RDM/.RDC/.R3D), BRAW (.braw más sidecar), P2 y XAVC se copian tal cual,
  manteniendo el árbol de carpetas. Aplanarlo rompería el relink en el editor.
- Rechaza una copia y un backup que sean el mismo disco físico (lo comprueba vía DiskArbitration),
  porque eso no sería un backup de verdad.
- Cada tarjeta genera un manifiesto con el registro de lo que se copió: origen, destino y hash.

### Cómo está organizado el proyecto

- `Sources/OffloadKit` es el motor, en Swift puro, sin interfaz: lectura de la tarjeta, copia,
  verificación, nombres por plantilla, manifiesto y memoria de presets.
- `Sources/CardflowApp` es la interfaz en SwiftUI.
- `Sources/cardflow` y `Sources/CardflowCLI` son la versión de línea de comandos, que usa el mismo
  motor.

### Compilar desde el código

Necesitas Swift 6 (Xcode 16 o las Command Line Tools).

```sh
swift build
swift run cardflow --help
bash scripts/make-app.sh
```

Para generar la versión firmada y empaquetada en DMG, mira [`docs/notarizacao.md`](docs/notarizacao.md)
y los scripts en `scripts/`.

### Requisitos

macOS 14 o más reciente.

## Licencia

[MIT](LICENSE). Úsalo, modifícalo y distribúyelo a tu gusto, solo manteniendo el aviso de copyright.
