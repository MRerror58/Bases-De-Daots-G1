# S22 · Guía de ejecución y sustentación — Grupo 1

## Qué hacemos

S20 dejó la biblioteca normalizada: `libro → ejemplar → prestamo`.
S21 explicó procedimientos y triggers; S22 los usa sin receta.

- **Parte A**: reservas de salas del profesor. `S22-reservas.sql` crea el escenario y `S22-grupo.sql` completa A1–A6. Las pruebas de errores **deben dar errores** (por eso no es apropiado abortar todo el archivo al primer error esperado).
- **Parte B / Hito 4**: en `programacion.sql` construimos procedimientos y triggers que protegen la biblioteca real; `pruebas-programacion.sql` demuestra un caso válido y casos rechazados. Los datos de prueba quedan dentro de `BEGIN … ROLLBACK`.

## Ejecutar en Fedora con Podman

Abre VS Code o la terminal en **la raíz del repositorio**. Elige el nombre que te aparezca:

```bash
podman ps --format '{{.Names}}'
PG=biblioteca-postgres    # o PG=curso_postgres, según tu equipo
```

### Parte A

```bash
podman exec -i "$PG" psql -U curso -d curso -f - < postgres/scripts/S22-reservas.sql
podman exec -i "$PG" psql -U curso -d curso -f - < postgres/scripts/S22-grupo.sql 2>&1 | tee docs-S22/salida-parte-A.txt
```

**Importante:** la segunda salida tiene errores intencionales: son los casos que `CHECK`, el procedimiento y los triggers deben rechazar. Mira los `NOTICE` y los resultados de cada batería; no evalúes el script solo porque muestra líneas `ERROR`.

### Parte B, sin tocar la biblioteca real

En una base de pruebas independiente, se carga el esquema S20 y la lógica S22:

```bash
podman exec "$PG" psql -U curso -d curso -c 'CREATE DATABASE prueba_s22;'
# Si ya existe, puedes usarla; el 01_esquema.sql recrea SOLO biblioteca dentro de prueba_s22.
podman exec -i "$PG" psql -U curso -d prueba_s22 -f - < postgres/init/01_esquema.sql
podman exec -i "$PG" psql -U curso -d prueba_s22 -f - < postgres/scripts/programacion.sql
podman exec -i "$PG" psql -U curso -d prueba_s22 -f - < postgres/scripts/pruebas-programacion.sql 2>&1 | tee docs-S22/salida-pruebas-programacion.txt
```

**Nunca ejecutes `01_esquema.sql` contra tu base principal `curso` si contiene datos que quieras conservar:** al principio tiene `DROP SCHEMA biblioteca CASCADE`. En `prueba_s22` sí es seguro para la práctica.

Para ver las tablas en psql:

```bash
podman exec "$PG" psql -U curso -d prueba_s22 -c '\dt biblioteca.*'
```

Y en pgAdmin, agrega/abre la base `prueba_s22` y el esquema `biblioteca`.

### Qué debes ver en las pruebas B

| Caso | Resultado esperado |
|---|---|
| Disponibilidad antes | 2 ejemplares |
| Registrar préstamo válido | `NOTICE` de préstamo registrado; disponibilidad 1 |
| Prestar segunda copia del mismo libro al mismo lector | Rechazado por trigger |
| Insertar préstamo directo con usuario no bibliotecario | Rechazado por trigger |
| Prestárselo al segundo lector | Aceptado; disponibilidad 0 |
| Registrar devolución con usuario no bibliotecario | Rechazado |
| Registrar devolución con bibliotecario | Aceptado; disponibilidad 1 |
| Actualizar devolución directamente con usuario no bibliotecario | Rechazado por trigger |

La prueba de la Parte B termina con `ROLLBACK`, así que deja la base como estaba. Guarda el archivo de salida generado en `docs-S22/`.

## Qué responde cada archivo

| Archivo | Función |
|---|---|
| `S22-reservas.sql` | Crea salas, estudiantes, reservas y función `dia(n)` |
| `S22-grupo.sql` | A1: CHECK/FK; A2: funciones; A3: procedimientos; A4–A5: triggers; A6: UPDATE en conjunto |
| `docs-S22/S22-respuestas.md` | Justificaciones pedidas en A1, A4, A5, A6 |
| `programacion.sql` | Dos procedimientos y dos triggers útiles en la biblioteca normalizada |
| `pruebas-programacion.sql` | Datos de prueba, resultados esperados, rechazos y cambio de disponibilidad |
| `03_programacion.sql` | Copia de la programación para arrancar con una base vacía, después de `01_esquema.sql` |

## Guion oral breve

> En la Parte A trabajamos un sistema de reservas. Las restricciones `CHECK` validan una fila, pero no pueden mirar la capacidad de otra tabla ni detectar choques entre otras reservas. Por eso creamos funciones que calculan horas y disponibilidad, procedimientos para reservar y cancelar, un trigger `BEFORE` que protege los `INSERT/UPDATE` directos y uno `AFTER` que sanciona una inasistencia. Cerramos reservas vencidas con una sentencia `UPDATE` sobre el conjunto.
>
> En nuestra biblioteca real, normalizada desde S20, `prestamo` apunta a un ejemplar físico. El procedimiento registra el préstamo buscando una copia disponible y validando al lector. Dos triggers impiden que alguien sin rol de bibliotecario registre movimientos y que un lector tenga abiertas dos copias del mismo libro. No guardamos `ejemplares_disponibles`: se calcula con la vista `libro_disponibilidad`; por eso no inventamos un trigger para mantener un contador que decidimos eliminar.

## Distinguir lo que falta de lo que ya está

- El **entregable inmediato de la Parte A** es `S22-grupo.sql` más respuestas. Ya estaban en el ZIP; este paquete agrega el script base para poder ejecutarlos.
- El **Hito 4**, con fecha propia, añade los scripts de programación de biblioteca, init actualizado, README y evidencia. Este paquete prepara esas piezas; la evidencia solo queda respaldada cuando ejecutes las pruebas en tu PostgreSQL y guardes el resultado real.
