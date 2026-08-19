# Pasos de la construcción de la ISO  

Explicados para que puedas crear tu propia distribución a partir de este script.  

---
## Fase 0  
Comprueba que tengas instaladas las dependencias. Según estés construyendo el sistema basado en Debian o en Arch necesitarás unas u otras.  

## Fase 1  
Descarga una imagen limpia de Arch o Debian y la deja en conserva, para luego poder copiarla rapidamente en las proximas construccione spara empezar desde una base limpia.

## Fase 2  
Crea la base necesaria tanto en Arch como en Debian para comenzar a construir los paquetes.

## Fase 3  
Clona la base limpia al rootfs para empezar a personalizar a partir de la base limpia, nunca una cosa encima de otra.

## Fase 4  
Monta los sistemas de archivos necesarios y configura el acceso a internet,para poder bajar archivos de internet (repo Inled o paquetes de terceros) 

## Fase 5  
Configura los repositorios de Inled, instala los paquetes necesarios de la distribución (calamares, etc...) hace una chapuza para que funcione autokey (necesario para el remap) y procede a crear los ajustes de Calamares. Aquí se instalan tanto los paquetes de /PKG subidos al repo de Inled como otros paquetes de Inled

## Fase 5.5  
Instala las aplicaciones externas, configura flatpak e instala hidamari por Flatpak.  
Asimismo configura el OS release y el autologin para el usuario live

## Fase 6  
Crea el sistema de archivos de ram (init ram fs) de arranque con mkinitcpio, crea logos transparentes para Arch y Debian, añade el menu entry de GRUB, parchea el copytoram de archlinux para que vaya mostrando el progreso...

## Fase 7  
Empaqueta la ISO: coppia el kernel y el initrd, desmonta el rootfs y lo comprime en un squashfs, que es basicamente un reducto de todo el sistema de archivos, en reduccion Pedro Ximenez :)
Mete el kernel y el initrd al iso staging, configura los parametros de arranque para cada entry e instala los iconos y empaqueta tanto la grub como el refind previamente configurados.

---
Y con esto ya tendríamos una ISO usable de Pulsar OS.
