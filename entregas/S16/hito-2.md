# S16, Hito 2: esquema, carga de datos y los cuatro reportes

**Grupo 1 · Proyecto Biblioteca**

| Integrante | Código |
|---|---|
| Santiago Ruiz Vanegas | 202177804 |
| Juan David Vasquez Cañas | 2515123 |
| Omar Esteban Agredo Titimbo | 2516317 |

## Contenido de la carpeta

| Archivo | Qué es |
|---|---|
| `01_esquema.sql` | Esquema `biblioteca` como script de arranque: `usuario`, `lector`, `libro`, `prestamo` y las tablas auxiliares de la carga. |
| `carga-libros.sql`, `carga-lectores.sql` | Cargas desde CSV (S14): tabla de paso, validación, tabla final y bitácora `rechazo_carga`, todo en una transacción. Repetir una carga no duplica nada. |
| `libros_propio.csv` | CSV propio del grupo para probar la carga (carga 5 filas y rechaza 3). |
| `S14-mapeo-criterios.md` | Mapeo CSV → esquema y criterio para cada tipo de error. |
| `S14-salida-cargas.txt` | Salida de las cargas: libros limpio, libros con errores, lectores con errores y CSV propio. |
| `S14-ultima-linea-defensa.md`, `S14-salida-ultima-linea-defensa.txt` | Prueba con una regla de validación comentada: el `CHECK` del esquema aborta la carga completa. |
| `reportes.sql` | Préstamos de prueba y los cuatro reportes del proyecto sobre el esquema del grupo. |
| `salida-reportes.txt` | Salida de `reportes.sql` (con cada consulta impresa). |

## Cómo correrlo

Desde `entorno-docker/`, con el esquema en `postgres/init/`, los scripts en `postgres/scripts/` y los CSV en `postgres/scripts/datos/`:

```bash
docker compose exec postgres psql -U curso -d curso -f /scripts/carga-libros.sql
docker compose exec postgres psql -U curso -d curso -f /scripts/carga-lectores.sql
docker compose exec postgres psql -U curso -d curso -f /scripts/reportes.sql
```

## Datos de préstamos

La base cargada tiene 32 libros, 20 lectores y ningún préstamo, así que `reportes.sql` inserta primero 15 préstamos de prueba con un usuario de rol `bibliotecario` (la carga de S14 solo crea cuentas de lectores). Todo va dentro de `BEGIN … ROLLBACK`: los reportes ven los préstamos y la base queda igual que antes. Las fechas se calculan desde `CURRENT_DATE` con un plazo de 14 días, por lo que la mora da lo mismo cualquier día que se corra.

| Lector | Préstamos | Situación |
|---|---|---|
| Mariana Gómez Rojas | 3 | Los 3 devueltos a tiempo |
| Santiago Rodríguez Pérez | 3 | Los 3 devueltos; el Quijote, 6 días tarde |
| Valentina López Díaz | 3 | 1 devuelto, 1 abierto en mora, 1 abierto a tiempo |
| Juan David Martínez Ruiz | 3 | 3 abiertos: 2 en mora y Rayuela, que vence hoy |
| Camila Hernández Torres | 3 | 2 devueltos, 1 abierto en mora |
| Los otros 15 lectores | 0 | Sin préstamos |

Total: 15 préstamos, 6 abiertos y 4 en mora.

## Los cuatro reportes

**1. Libros más prestados.** `LEFT JOIN` de `libro` con `prestamo`, para que un libro sin préstamos cuente 0, y `FETCH FIRST 3 ROWS WITH TIES`, para no cortar un empate en el tercer puesto. Resultado: *Cien años de soledad* (4), *Rayuela* (3) y *Ficciones* (2).

**2. Lectores que más han leído.** Cuenta los préstamos devueltos por lector en un CTE y se queda con los que igualan el máximo, así que si hay empate salen todos. Resultado: Mariana Gómez y Santiago Rodríguez, con 3 cada uno.

**3. Lectores morosos.** Un lector es moroso si tiene al menos un préstamo abierto (`fecha_devolucion IS NULL`) con `fecha_vencimiento < CURRENT_DATE`. Se usa `EXISTS` para que un lector con dos libros en mora salga una sola vez. Resultado: Camila Hernández, Valentina López y Juan David Martínez. Santiago no sale: su atraso ya se cerró con la devolución.

**4. Préstamos en mora para notificar.** Une préstamo, lector y libro. Devuelve correo, teléfono, título, fecha de vencimiento y días de mora, ordenado de mayor a menor mora. Resultado: 4 préstamos, entre 2 y 26 días. *Rayuela* de Juan David vence hoy y no aparece, porque la comparación es `<` y no `<=`.

Las cifras exactas de días de mora y fechas están en `salida-reportes.txt` (corrida del 2026-11-21).

## Pendiente para los siguientes hitos

- `prestamo` no tiene valores por defecto en las fechas, y nada valida que `registrado_por` sea un bibliotecario. Eso es de un trigger (Hito 4).
- `ejemplares_disponibles` no baja con un préstamo: los préstamos de prueba no la modifican. Se decide en S20 si se calcula en una vista o la mantiene un trigger.
- El cambio obligatorio de la contraseña inicial de los lectores queda para el Hito 5.
