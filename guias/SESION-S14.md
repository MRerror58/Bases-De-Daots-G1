# Notas de sesión S14 (borrar después de leer)

Carpeta de trabajo: `C:\Users\Stran\Downloads\entorno-docker\entorno-docker`

## Estado

Todo lo que pide la guía de S14 está hecho y probado en Docker:

- Esquema de la biblioteca como script de arranque: `postgres/init/01_esquema.sql`. Probado arrancando la base vacía: crea las 8 tablas sin intervención.
- Cargas: `postgres/scripts/carga-libros.sql` y `postgres/scripts/carga-lectores.sql`.
- CSV: los 4 de la semilla y el propio (`libros_propio.csv`) en `postgres/scripts/datos/`.
- Documentos de la entrega en `docs-S14/`:
  - `S14-mapeo-criterios.md`: mapeo CSV → esquema y criterios por tipo de error.
  - `S14-salida-cargas.txt`: salida de las cargas (libros limpio, libros con errores, lectores con errores, CSV propio).
  - `S14-ultima-linea-defensa.md` y `S14-salida-ultima-linea-defensa.txt`: la prueba con la regla comentada.

Resultados: los 14 errores del curso atrapados, el CSV propio carga 5 y rechaza 3, y repetir una carga no duplica nada. Sin la regla de ejemplares negativos, el `CHECK` del esquema aborta toda la carga y la bitácora queda sin cambios.

La base en Docker tiene ahora solo las dos cargas limpias (32 libros, 20 lectores). No tiene la bitácora ni el CSV propio de la salida guardada.

## Pendiente (lo hace el grupo)

1. Confirmar la contraseña inicial de los lectores: el documento, guardado con hash bcrypt. El cambio obligatorio queda para el Hito 5.
2. Confirmar los criterios de `docs-S14/S14-mapeo-criterios.md`.
3. Subir al repo del grupo y al campus: `postgres/init/01_esquema.sql`, los dos scripts de carga, `libros_propio.csv` y los archivos de `docs-S14/`. Esta carpeta no es un repo git.
4. Revisar la línea 4 de `libros_semilla_con_errores.csv`: el CSV trae `dos` en la columna del año, así que el motivo dice "año no numérico" y no "ejemplares no numérico" como en la guía.

## Comandos útiles (desde esta carpeta)

```powershell
docker compose up -d
docker compose exec postgres psql -U curso -d curso -f /scripts/carga-libros.sql
docker compose exec postgres psql -U curso -d curso -v archivo=/scripts/datos/libros_propio.csv -f /scripts/carga-libros.sql
docker compose exec postgres psql -U curso -d curso -f /scripts/carga-lectores.sql
docker compose exec postgres psql -U curso -d curso -c "SELECT * FROM biblioteca.rechazo_carga"
```

pgAdmin: http://localhost:5050 (usuario `estudiante@curso.edu.co`, contraseña `curso`).

Para reiniciar desde cero con el esquema: `docker compose down`, borrar `postgres/data/pgdata` y `docker compose up -d`.

## Para el Hito 2 (S16), no es de S14

Consultas de los cuatro reportes y datos de préstamos para que devuelvan algo. Se ven en S15. El esquema de su grupo todavía no tiene trigger ni procedimiento (Hito 4), y `prestamo` no tiene defaults en las fechas.
