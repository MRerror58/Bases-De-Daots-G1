# S20: desnormalización para rendimiento y Hito 3

**Grupo 1 · Proyecto Biblioteca** · Santiago Ruiz Vanegas (202177804), Juan David Vasquez Cañas (2515123), Omar Esteban Agredo Titimbo (2516317)

## Contenido de la carpeta

| Archivo | Qué es |
|---|---|
| `parte-A.md` | Parte A: tabla de mediciones y respuestas de A1 a A5. |
| `parte-A.sql`, `salida-parte-A.txt` | El script de la parte A sobre el esquema `rendimiento` y su salida, con los planes de `EXPLAIN ANALYZE`. |
| `S20-rendimiento.sql` | El script del profesor que genera el esquema `rendimiento`. `parte-A.sql` lo ejecuta al empezar. |
| `hito-3.md` | **Documento de normalización del Hito 3** (secciones 1 a 6). |
| `01_esquema.sql` | Copia de `postgres/init/01_esquema.sql`: el esquema normalizado. |
| `normalizacion.sql`, `salida-normalizacion.txt` | Migración de la base del grupo al esquema nuevo, y su salida (evidencia, conteos, `EXCEPT`). |
| `salida-prueba-migracion.txt` | La misma migración sobre una copia con los 15 préstamos de prueba de S16, y una segunda corrida que se detiene sin tocar nada. |
| `carga-libros.sql`, `carga-lectores.sql` | Las cargas de S14 ajustadas al esquema nuevo. |
| `salida-init-y-cargas.txt` | `01_esquema.sql` en una base vacía más las cuatro cargas de S14 y el CSV propio. |
| `reportes.sql`, `salida-reportes.txt` | Los cuatro reportes de S16 sobre el esquema nuevo. |
| `pruebas-restricciones.sql`, `salida-pruebas-restricciones.txt` | Lo que el esquema de S19 aceptaba, rechazado ahora por una restricción con nombre. |

## Cómo correrlo

Desde `entorno-docker/`, con los `.sql` en `postgres/scripts/` y el esquema en `postgres/init/`:

```bash
# Parte A (recarga el esquema rendimiento; no toca biblioteca)
docker compose exec postgres psql -U curso -d curso -f /scripts/parte-A.sql

# Parte B sobre la base del grupo, que ya tiene el esquema de S16 y las cargas
docker compose exec postgres psql -U curso -d curso -f /scripts/normalizacion.sql
docker compose exec postgres psql -U curso -d curso -f /scripts/reportes.sql
docker compose exec postgres psql -U curso -d curso -f /scripts/pruebas-restricciones.sql

# Probar init/ sin borrar la base del grupo
docker compose exec postgres psql -U curso -d curso -c "CREATE DATABASE prueba_init;"
docker compose exec postgres psql -U curso -d prueba_init -f /docker-entrypoint-initdb.d/01_esquema.sql
docker compose exec postgres psql -U curso -d prueba_init -f /scripts/carga-libros.sql
docker compose exec postgres psql -U curso -d prueba_init -f /scripts/carga-lectores.sql
docker compose exec postgres psql -U curso -d curso -c "DROP DATABASE prueba_init;"
```

`reportes.sql` y `pruebas-restricciones.sql` trabajan dentro de `BEGIN … ROLLBACK`: la base queda como estaba.

Las salidas se generaron el 2026-11-22 con PostgreSQL 16 (imagen `postgres:16`). Los tiempos de la parte A dependen del computador; lo que se compara son los órdenes de magnitud.
