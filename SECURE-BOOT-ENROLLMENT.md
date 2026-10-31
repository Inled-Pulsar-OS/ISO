# Guía de Enrolamiento Secure Boot (MOK) en Pulsar OS
# Pulsar OS Secure Boot (MOK) Key Enrollment Guide

Esta guía explica cómo registrar la clave de Pulsar OS en MokManager al arrancar por primera vez con **Secure Boot** activado (tanto en máquinas reales como en máquinas virtuales UEFI).

---

## 🇪🇸 Español

### ¿Por qué aparece esta pantalla?
Pulsar OS utiliza el cargador oficial **shim** firmado por Microsoft. La primera vez que arranca un cargador de arranque firmado por Pulsar (como **rEFInd**), el firmware detecta que la clave aún no está en la base de datos de claves de la máquina (MOK - Machine Owner Key) y abre automáticamente el menú azul **MokManager**.

Este paso solo se realiza **una única vez**.

---

### Paso a paso para enrolar la clave

1. **Pantalla inicial de MokManager**:
   - Verás un mensaje en azul: *"Press any key to perform MOK management"*.
   - Pulsa cualquier tecla o **Enter** antes de que termine la cuenta atrás.

2. **Menú principal "Perform MOK management"**:
   - Usa las flechas del teclado para bajar y seleccionar:
     👉 **`Enroll key from disk`**
   - Pulsa **Enter**.

3. **Seleccionar la partición**:
   - Aparecerá una lista con los discos y particiones disponibles (por ejemplo `PulsarOS`, la partición EFI o el disco USB/CD).
   - Selecciona la partición de arranque de Pulsar OS y pulsa **Enter**.

4. **Navegar a la clave**:
   - Entra en la carpeta **`EFI`** (pulsa Enter).
   - Entra en la carpeta **`BOOT`** (pulsa Enter).
   - Selecciona el archivo del certificado:
     👉 **`refind.cer`**
   - Pulsa **Enter**.

5. **Confirmar la clave**:
   - Puedes seleccionar *View Key* para inspeccionar los datos (Organización: *Pulsar OS*) o seleccionar directamente **`Continue`**.
   - En la siguiente pantalla (*Enroll the key(s)?*), selecciona:
     👉 **`Yes`**
   - Pulsa **Enter**.

6. **Reiniciar el sistema**:
   - Selecciona **`Reboot`** (o **`Continue boot`**).

¡Listo! A partir de este momento, el firmware UEFI de la placa base confiará de forma permanente en la clave MOK de Pulsar OS, permitiendo arrancar **rEFInd**, los kernels y el sistema operativo de forma 100% segura y automática sin volver a mostrar este aviso.

---

## 🇬🇧 English

### Why does this screen appear?
Pulsar OS uses the official Microsoft-signed **shim** bootloader. The first time a Pulsar-signed bootloader (such as **rEFInd**) boots, the firmware detects that the certificate is not yet in the machine's key database (MOK - Machine Owner Key) and launches **MokManager** (blue screen).

This enrollment process only needs to be completed **once**.

---

### Step-by-Step Instructions

1. **Initial MokManager Prompt**:
   - When you see *"Press any key to perform MOK management"*, press any key or **Enter** before the timeout expires.

2. **Main Menu "Perform MOK management"**:
   - Navigate down with the arrow keys and select:
     👉 **`Enroll key from disk`**
   - Press **Enter**.

3. **Select Partition**:
   - Choose the bootable installation partition (USB, CD, or EFI system partition) from the list.
   - Press **Enter**.

4. **Navigate to the Certificate**:
   - Open directory **`EFI`** (press Enter).
   - Open directory **`BOOT`** (press Enter).
   - Select:
     👉 **`refind.cer`**
   - Press **Enter**.

5. **Confirm Key Enrollment**:
   - Select **`Continue`** (or *View Key* to inspect the certificate).
   - When asked *Enroll the key(s)?*, select:
     👉 **`Yes`**
   - Press **Enter**.

6. **Reboot**:
   - Select **`Reboot`** (or **`Continue boot`**).

Your UEFI firmware now permanently trusts the Pulsar OS MOK key. Future boots into **rEFInd** and signed Linux kernels will proceed automatically without any prompts.
