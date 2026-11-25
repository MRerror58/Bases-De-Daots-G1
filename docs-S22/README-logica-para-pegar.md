## Lógica en la base de datos — S22 / Hito 4

El proyecto utiliza PostgreSQL, con el esquema `biblioteca` normalizado en S20.
Las copias físicas están en `ejemplar` y los préstamos apuntan a `id_ejemplar`.
La disponibilidad no se almacena como un contador: se calcula en la vista
`biblioteca.libro_disponibilidad`.

| Objeto | Tipo | Tabla/evento | Regla que implementa |
|---|---|---|---|
| `registrar_prestamo` | Procedimiento | Inserción en `prestamo` | Lector habilitado y sin mora; máximo 3 préstamos abiertos; personal autorizado; libro activo y ejemplar libre |
| `registrar_devolucion` | Procedimiento | Actualización en `prestamo` | Completa fecha y bibliotecario responsable de una devolución |
| `prestamo_validar_personal` | Trigger `BEFORE` | `INSERT` / `UPDATE OF registrado_por, devuelto_por` | Solo usuarios activos con rol `bibliotecario` pueden registrar préstamos/devoluciones |
| `prestamo_un_libro_abierto` | Trigger `BEFORE` | `INSERT` / `UPDATE OF id_lector, id_ejemplar, fecha_devolucion` | Un mismo lector no puede tener dos copias del mismo libro prestadas simultáneamente |
| `prestamo_abierto_key` (S20) | Índice único parcial | `prestamo(id_ejemplar)` abierto | Una misma copia no puede estar prestada simultáneamente a dos lectores |
| `libro_disponibilidad` (S20) | Vista | `ejemplar` + `prestamo` | Disponibles calculados en tiempo de consulta; no requiere trigger de contador |

**Archivos:** `postgres/scripts/programacion.sql`, `postgres/scripts/pruebas-programacion.sql` y `postgres/init/03_programacion.sql`.

**Pruebas:** ejecutar en una base de ensayo llamada `prueba_s22`, con la tabla de resultados esperados y la salida de PostgreSQL conservada en `docs-S22/salida-pruebas-programacion.txt`. Los datos de prueba se revierten con `ROLLBACK`.
