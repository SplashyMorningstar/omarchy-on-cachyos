# Omarchy en CachyOS (experimental)

Instalador experimental basado en [mroboff/omarchy-on-cachyos](https://github.com/mroboff/omarchy-on-cachyos), adaptado al sistema de paquetes de Omarchy 4.

El instalador comprueba CachyOS x86_64, Btrfs en `/` y una configuración Snapper llamada `root`. Después configura el repositorio oficial estable, instala los paquetes base de Omarchy, aplica sus configuraciones al usuario actual con copias de seguridad y ejecuta la preparación de usuario.

## Instalación

Ejecuta estos comandos como tu usuario normal de CachyOS, **no** con `sudo`:

### 1. Clona el repositorio

```bash
git clone https://github.com/SplashyMorningstar/omarchy-on-cachyos.git
cd omarchy-on-cachyos
```

### 2. Da permisos de ejecución al instalador y al desinstalador

```bash
chmod +x install-omarchy-on-cachyos.sh uninstall-omarchy-on-cachyos.sh
```

### 3. Ejecuta el instalador

```bash
./install-omarchy-on-cachyos.sh
```

Revisa el aviso y escribe `INSTALL` para confirmar. El script actualiza el sistema e instala Omarchy. Los archivos de configuración existentes que vaya a reemplazar se guardan en `~/.local/backups/`.

Al terminar, cierra sesión y selecciona **Omarchy (Hyprland uwsm)** en SDDM; no selecciones la sesión Hyprland genérica de CachyOS.

### Reparar/aplicar la configuración de usuario

Si Omarchy ya está instalado pero la configuración de usuario no se completó, actualiza el repositorio y ejecuta:

```bash
git pull
./install-omarchy-on-cachyos.sh --apply-user-configs
```

Escribe `APPLY-OMARCHY-CONFIGS` para confirmar. El script instalará los paquetes base que falten, respaldará los archivos coincidentes, aplicará los valores de Omarchy y volverá a ejecutar la preparación del usuario.

## Desinstalación

Desde el directorio del repositorio, ejecuta como usuario normal:

```bash
./uninstall-omarchy-on-cachyos.sh
```

Escribe `REMOVE-OMARCHY` para confirmar. El desinstalador archiva los datos específicos de Omarchy y elimina los paquetes con nombre `omarchy` o `omarchy-*`, el repositorio de pacman y su clave. No elimina KDE ni dependencias compartidas, conserva configuraciones Hyprland que podrían pertenecer a CachyOS y **no modifica el cargador de arranque**.

## Limitaciones importantes

- Es un método experimental y no oficial. Btrfs por sí solo no garantiza que Snapper o la recuperación del arranque estén correctamente configurados; conserva una copia de seguridad externa.
- El instalador usa la versión **estable actual** de Omarchy, no fija una versión histórica como 4.0.5.
- Después de instalar Omarchy, usa `omarchy update` para actualizarlo. No uses `pacman -Syu` directamente para saltarte el flujo de actualización de Omarchy.
- La instalación no formatea ni reparte discos, no desinstala KDE y no configura automáticamente el cargador de arranque.
