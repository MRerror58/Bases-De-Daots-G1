# S20, parte A: medir, indexar, desnormalizar

**Grupo 1 · Proyecto Biblioteca**

| Integrante | Código |
|---|---|
| Santiago Ruiz Vanegas | 202177804 |
| Juan David Vasquez Cañas | 2515123 |
| Omar Esteban Agredo Titimbo | 2516317 |

Esquema `rendimiento` del script `S20-rendimiento.sql` (5 000 títulos, 15 000 ejemplares, 2 000 lectores, 303 750 préstamos, 3 750 abiertos). Todo lo que sigue sale de `parte-A.sql`; su salida completa, con los planes, está en `salida-parte-A.txt`. El script recarga el esquema al empezar, así que siempre parte sin índices extra.

Cada consulta se midió tres veces con `EXPLAIN ANALYZE` (la función `medir()` del script corre el `EXPLAIN` y devuelve solo el `Execution Time`). PostgreSQL 16 en Docker, en un portátil con Windows 11.

## Tabla de mediciones

| Consulta | Sin índices | Con índices (A2) | Desnormalizada (A3 o A4) |
|---|---|---|---|
| Catálogo (`Libro 12%`, 111 títulos) | ~27 ms (28,6 / 26,4 / 26,5) | ~3,7 ms (3,0 / 4,2 / 3,7) | ~1 ms (1,0 / 1,0 / 0,6), columna `disponibles` |
| Top 20 más prestados | ~355 ms (409 / 355 / 318) | (no aplica) | ~0,02 ms (0,028 / 0,018 / 0,015), vista materializada |

Lo que dicen los números: en el catálogo, el índice baja el tiempo unas 7 veces sin agregar ninguna copia al modelo. La columna desnormalizada gana otro poco, pero sobre 3,7 ms, una diferencia que nadie nota al buscar un libro, y a cambio puede mentir (A3 c). En el top 20 el índice no ayuda, porque hay que contar todos los préstamos; ahí la vista materializada sí cambia el orden de magnitud.

## A1. La consulta del catálogo

**(a)** El `LEFT JOIN` conserva los ejemplares que no tienen un préstamo abierto: con `JOIN` desaparecerían y el libro contaría solo los ejemplares prestados. `count(p.id)` cuenta solo los préstamos que existen, porque ignora los `NULL` que deja el `LEFT JOIN`. Con `count(*)` cada fila cuenta 1, tenga o no préstamo, y la resta siempre da 0. El script lo prueba: con `count(p.id)` ningún libro queda en 0; con `count(*)`, los 111 quedan en 0.

**(b)** ~27 ms (tabla de arriba).

**(c)** El nodo costoso es el más indentado de la rama izquierda del join:

```
->  Seq Scan on prestamo p (actual time=22.573..23.074 rows=3750 loops=1)
      Filter: (fecha_devolucion IS NULL)
      Rows Removed by Filter: 300000
```

Recorre los 303 750 préstamos para quedarse con los 3 750 abiertos, y descarta 300 000. Termina en el milisegundo 23 de una consulta de 28: se lleva unas cuatro quintas partes del tiempo. Lo demás (buscar los 111 títulos y sus 333 ejemplares) toma unos 4 ms.

## A2. Índices

```sql
CREATE INDEX ejemplar_isbn_idx    ON ejemplar (isbn);
CREATE INDEX prestamo_abierto_idx ON prestamo (id_ejemplar) WHERE fecha_devolucion IS NULL;
```

El `Seq Scan on prestamo` desaparece. En su lugar hay un `Nested Loop Left Join` que, por cada uno de los 333 ejemplares, busca en el índice su préstamo abierto (`Index Scan using prestamo_abierto_idx ... loops=333`, menos de 0,001 ms cada búsqueda). El planificador siguió leyendo `ejemplar` completa con `Seq Scan` (15 000 filas, menos de 1 ms): es una tabla pequeña y le sale más barato recorrerla que usar `ejemplar_isbn_idx`.

No hubo que agregar ninguna redundancia al modelo. El índice lo mantiene PostgreSQL en cada `INSERT`, `UPDATE` y `DELETE`, así que no se puede desincronizar. El parcial ocupa 104 kB porque solo indexa los 3 750 préstamos abiertos; el de la PK, que indexa los 303 750, ocupa 6 680 kB.

## A3. Desnormalizar `disponibles`

**(a) Predicción, antes del `UPDATE`:** los ejemplares del libro i son 3i-2, 3i-1 y 3i. Entre tres números seguidos hay a lo sumo un múltiplo de 4, así que ningún libro tiene dos préstamos abiertos. Hay 15 000 / 4 = 3 750 ejemplares múltiplos de 4, cada uno de un libro distinto: **3 750 libros con 2 disponibles y 1 250 con 3**. El resultado del `UPDATE` coincide:

| disponibles | libros |
|---|---|
| 2 | 3 750 |
| 3 | 1 250 |

La columna se agregó primero sin `NOT NULL`, se llenó con un solo `UPDATE` y después se le puso `NOT NULL` y `CHECK (disponibles >= 0)`. Con `ADD COLUMN ... NOT NULL` sin `DEFAULT`, el `ALTER` falla porque la tabla ya tiene filas.

**(b)** `SELECT isbn, titulo, disponibles FROM libro WHERE titulo LIKE 'Libro 12%'` queda en un `Seq Scan on libro` de 5 000 filas: ~1 ms.

**(c)** La vista `descuadre` compara la copia guardada con el cálculo y devuelve solo las filas que no coinciden. Recién llenada la columna devuelve 0 filas. Después del préstamo 400001 del ejemplar 1, que no actualizó la copia:

| isbn | titulo | guardado | calculado |
|---|---|---|---|
| 9780000000001 | Libro 1 | 3 | 2 |

El catálogo desnormalizado sigue ofreciendo 3 ejemplares de Libro 1 cuando solo quedan 2 en el estante.

**(d)** Un **trigger** sobre `prestamo`: un préstamo abierto nuevo resta 1 al libro de su ejemplar, y registrar la devolución suma 1. Es el único mecanismo de la tabla de la sección 5 que mantiene la copia al día sin depender de que cada programa se acuerde: el `INSERT` de (c), hecho a mano desde `psql`, también lo dispararía. Que la aplicación actualice las dos cosas en la misma transacción falla exactamente en el caso de (c). Una vista materializada no sirve, porque el catálogo tiene que estar al día en el momento de prestar, y una columna generada tampoco, porque el dato depende de filas de otras tablas.

Para el proyecto, sin embargo, la decisión fue **no desnormalizar** `disponibles` (ver `hito-3.md`, sección 5): el índice parcial ya da casi toda la mejora y la vista calculada no puede desincronizarse.

## A4. El reporte de los 20 más prestados

**(a)** ~355 ms. El plan recorre los 303 750 préstamos (`Parallel Seq Scan on prestamo`), los une con ejemplar y libro, y agrupa por libro. Los índices de A2 no aparecen en el plan: para contar todos los préstamos hay que leerlos todos, y un índice solo ayuda a encontrar unos pocos.

**(b)** `top_prestados` devuelve las 20 filas en ~0,02 ms, porque solo lee la tabla ya calculada. Arriba quedan Libro 1 (3 881 préstamos), Libro 2 (1 881) y Libro 3 (1 401). Un `REFRESH MATERIALIZED VIEW top_prestados` tardó 194 ms: recalcular cuesta lo mismo que la consulta original.

**(c)** Antes de los 4 000 préstamos, Libro 5000 tenía 21. Después:

| Fuente | Primer lugar | ¿Aparece Libro 5000? |
|---|---|---|
| `top_prestados` sin refrescar | Libro 1 (3 881) | No (0 filas) |
| Consulta directa | Libro 5000 (4 021) | Sí, de primero |
| `top_prestados` después del `REFRESH` | Libro 5000 (4 021) | Sí, de primero |

La vista muestra el estado del momento del último `REFRESH`, no el actual.

**(d)** En la biblioteca del proyecto, refrescarla **una vez al día, de noche**, es suficiente: el reporte de "más prestados" sirve para decidir compras o exhibiciones, y ninguna de esas decisiones cambia por los préstamos de un día. Lo haría la API antes de servir el reporte si ya pasó un día desde el último `REFRESH`, o el bibliotecario con un botón "Actualizar ranking" en la pantalla del reporte. Un trabajo programado (cron) también sirve, pero queda fuera de lo que el curso alcanza a montar. Sí es aceptable que esté atrasado, siempre que la pantalla diga la fecha del último cálculo. Lo que no tiene sentido es refrescarla después de cada préstamo: cada `REFRESH` cuesta lo mismo que la consulta directa, y no se ganaría nada.

El proyecto tiene 32 libros y 94 ejemplares, contra 5 000 y 15 000 de este esquema, y la vista de disponibles del proyecto tarda ~0,3 ms, así que hoy no necesita la vista materializada. Queda como la opción para cuando el volumen se acerque al de este esquema.

## A5. ¿`fecha_esperada` es derivada o histórica?

En los datos generados el plazo es siempre de 14 días: la última consulta del script agrupa `fecha_esperada - fecha_prestamo` y da una sola fila, `14 | 307751`. Eso dice cómo se generaron los datos, no cuál es la regla del negocio.

- **Si el plazo nunca cambia y no hay excepciones**, `fecha_esperada = fecha_prestamo + 14` en todas las filas: es un dato derivado y guardarlo es redundancia. Se podría quitar y calcular en la consulta, o declarar como columna generada (`GENERATED ALWAYS AS (fecha_prestamo + 14) STORED`), que no se puede escribir a mano.
- **Si la biblioteca puede cambiar el plazo o dar plazos especiales** (renovaciones, libros de consulta, otro plazo para docentes), la fecha esperada es un hecho del préstamo: lo que se acordó con el lector ese día. Depende de la clave del préstamo, no de una regla vigente, y guardarla es correcto en 3FN. Calcularla con la regla del momento cambiaría las fechas de préstamos viejos cuando cambie el plazo, y haría aparecer o desaparecer moras que ya se notificaron.

En el proyecto aplica el segundo caso: cada equipo puede ajustar el plazo, y nuestro esquema guarda `prestamo.fecha_vencimiento` como dato histórico (así quedó anotado desde S19).
