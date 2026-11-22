-- =====================================================================
-- S20, parte A: medir, indexar, desnormalizar
-- Grupo 1 - Proyecto Biblioteca
-- Integrantes:
--   Santiago Ruiz Vanegas         (202177804)
--   Juan David Vasquez Cañas      (2515123)
--   Omar Esteban Agredo Titimbo   (2516317)
--
-- Uso (desde entorno-docker/, con este archivo y S20-rendimiento.sql en
-- postgres/scripts/):
--   docker compose exec postgres psql -U curso -d curso -f /scripts/parte-A.sql
--
-- Empieza recargando el esquema "rendimiento", así que se puede correr
-- cuantas veces se quiera y siempre parte de cero (sin índices extra).
-- =====================================================================

\set ON_ERROR_STOP on
\i /scripts/S20-rendimiento.sql
SET search_path TO rendimiento;

-- Cada consulta se mide tres veces. medir() corre EXPLAIN ANALYZE n veces
-- y devuelve solo el "Execution Time" de cada corrida; el plan completo se
-- imprime una vez aparte, antes de llamarla.
CREATE FUNCTION medir(consulta text, veces integer DEFAULT 3)
RETURNS TABLE (corrida integer, ms numeric)
LANGUAGE plpgsql AS $$
DECLARE
    plan json;
BEGIN
    FOR i IN 1..veces LOOP
        EXECUTE 'EXPLAIN (ANALYZE, FORMAT JSON) ' || consulta INTO plan;
        corrida := i;
        ms := round((plan -> 0 ->> 'Execution Time')::numeric, 3);
        RETURN NEXT;
    END LOOP;
END;
$$;

\set catalogo 'SELECT l.isbn, l.titulo, count(e.id_ejemplar) - count(p.id) AS disponibles FROM libro l JOIN ejemplar e ON e.isbn = l.isbn LEFT JOIN prestamo p ON p.id_ejemplar = e.id_ejemplar AND p.fecha_devolucion IS NULL WHERE l.titulo LIKE ''Libro 12%'' GROUP BY l.isbn, l.titulo'

\set top20 'SELECT l.isbn, l.titulo, count(*) AS prestamos FROM prestamo p JOIN ejemplar e ON e.id_ejemplar = p.id_ejemplar JOIN libro l ON l.isbn = e.isbn GROUP BY l.isbn, l.titulo ORDER BY prestamos DESC FETCH FIRST 20 ROWS WITH TIES'

-- ---------------------------------------------------------------------
\echo
\echo '== A1. La consulta del catálogo, sin índices =='
-- ---------------------------------------------------------------------

-- Resultado: cuántos títulos coinciden y cómo quedan los primeros.
SELECT count(*) AS titulos_que_coinciden FROM (:catalogo) c;
SELECT * FROM (:catalogo) c ORDER BY isbn FETCH FIRST 5 ROWS ONLY;

EXPLAIN (ANALYZE, COSTS OFF)
SELECT l.isbn, l.titulo, count(e.id_ejemplar) - count(p.id) AS disponibles
FROM   libro l
JOIN   ejemplar e      ON e.isbn = l.isbn
LEFT JOIN prestamo p   ON p.id_ejemplar = e.id_ejemplar
                      AND p.fecha_devolucion IS NULL
WHERE  l.titulo LIKE 'Libro 12%'
GROUP BY l.isbn, l.titulo;

SELECT * FROM medir(:'catalogo');

-- (a) Con count(*) cada ejemplar sin préstamo abierto contaría 1 en la
-- resta, y todos los libros saldrían con 0 disponibles. La prueba:
SELECT count(*) FILTER (WHERE bien = 0)  AS con_count_p_id_en_0,
       count(*) FILTER (WHERE mal  = 0)  AS con_count_estrella_en_0
FROM (SELECT count(e.id_ejemplar) - count(p.id) AS bien,
             count(e.id_ejemplar) - count(*)    AS mal
      FROM   libro l
      JOIN   ejemplar e    ON e.isbn = l.isbn
      LEFT JOIN prestamo p ON p.id_ejemplar = e.id_ejemplar
                          AND p.fecha_devolucion IS NULL
      WHERE  l.titulo LIKE 'Libro 12%'
      GROUP BY l.isbn) x;

-- ---------------------------------------------------------------------
\echo
\echo '== A2. Con índices =='
-- ---------------------------------------------------------------------

CREATE INDEX ejemplar_isbn_idx    ON ejemplar (isbn);
-- Parcial: solo los préstamos abiertos, que son los que el catálogo busca.
CREATE INDEX prestamo_abierto_idx ON prestamo (id_ejemplar) WHERE fecha_devolucion IS NULL;
ANALYZE;

EXPLAIN (ANALYZE, COSTS OFF)
SELECT l.isbn, l.titulo, count(e.id_ejemplar) - count(p.id) AS disponibles
FROM   libro l
JOIN   ejemplar e      ON e.isbn = l.isbn
LEFT JOIN prestamo p   ON p.id_ejemplar = e.id_ejemplar
                      AND p.fecha_devolucion IS NULL
WHERE  l.titulo LIKE 'Libro 12%'
GROUP BY l.isbn, l.titulo;

SELECT * FROM medir(:'catalogo');

-- Tamaño de cada índice: el parcial indexa 3 750 filas, no 303 750.
SELECT relname AS indice, pg_size_pretty(pg_relation_size(oid)) AS tamano
FROM   pg_class
WHERE  relname IN ('ejemplar_isbn_idx', 'prestamo_abierto_idx', 'prestamo_pkey')
ORDER BY relname;

-- ---------------------------------------------------------------------
\echo
\echo '== A3. Desnormalizar disponibles en libro =='
-- ---------------------------------------------------------------------

-- Predicción, antes del UPDATE: entre 3i-2, 3i-1 y 3i hay a lo sumo un
-- múltiplo de 4, y hay 15000 / 4 = 3 750 ejemplares múltiplos de 4. Cada
-- uno cae en un libro distinto: 3 750 libros con 2 disponibles y
-- 5 000 - 3 750 = 1 250 con 3.

-- Primero sin NOT NULL: si la tabla ya tiene filas, ADD COLUMN ... NOT NULL
-- sin DEFAULT falla. Se llena y después se pone la restricción.
ALTER TABLE libro ADD COLUMN disponibles smallint;

UPDATE libro l
SET    disponibles =
         (SELECT count(*) FROM ejemplar e WHERE e.isbn = l.isbn)
       - (SELECT count(*)
          FROM   prestamo p
          JOIN   ejemplar e ON e.id_ejemplar = p.id_ejemplar
          WHERE  e.isbn = l.isbn AND p.fecha_devolucion IS NULL);

ALTER TABLE libro ALTER COLUMN disponibles SET NOT NULL,
                  ADD CONSTRAINT libro_disponibles_check CHECK (disponibles >= 0);
ANALYZE libro;

SELECT disponibles, count(*) AS libros FROM libro GROUP BY disponibles ORDER BY disponibles;

\echo '-- (b) Catálogo leyendo la columna'
EXPLAIN (ANALYZE, COSTS OFF)
SELECT isbn, titulo, disponibles FROM libro WHERE titulo LIKE 'Libro 12%';

SELECT * FROM medir($$SELECT isbn, titulo, disponibles FROM libro WHERE titulo LIKE 'Libro 12%'$$);

\echo '-- (c) La vista que detecta el descuadre'
CREATE VIEW descuadre AS
SELECT   l.isbn, l.titulo,
         l.disponibles                          AS guardado,
         count(e.id_ejemplar) - count(p.id)     AS calculado
FROM     libro l
JOIN     ejemplar e    ON e.isbn = l.isbn
LEFT JOIN prestamo p   ON p.id_ejemplar = e.id_ejemplar
                      AND p.fecha_devolucion IS NULL
GROUP BY l.isbn, l.titulo, l.disponibles
HAVING   l.disponibles <> count(e.id_ejemplar) - count(p.id);

-- Recién llenada, la copia cuadra.
SELECT count(*) AS libros_descuadrados_antes FROM descuadre;

-- Alguien registra un préstamo del ejemplar 1 (Libro 1) y olvida la copia.
INSERT INTO prestamo VALUES (400001, 1, '1000000001', CURRENT_DATE, CURRENT_DATE + 14, NULL);

SELECT * FROM descuadre;

-- El catálogo desnormalizado sigue diciendo 3 disponibles para Libro 1,
-- aunque uno de sus tres ejemplares acaba de salir.
SELECT isbn, titulo, disponibles FROM libro WHERE titulo = 'Libro 1';

-- ---------------------------------------------------------------------
\echo
\echo '== A4. Top 20 más prestados =='
-- ---------------------------------------------------------------------

\echo '-- (a) Consulta directa (los índices de A2 ya existen y no le sirven)'
EXPLAIN (ANALYZE, COSTS OFF)
SELECT   l.isbn, l.titulo, count(*) AS prestamos
FROM     prestamo p
JOIN     ejemplar e ON e.id_ejemplar = p.id_ejemplar
JOIN     libro    l ON l.isbn = e.isbn
GROUP BY l.isbn, l.titulo
ORDER BY prestamos DESC
FETCH FIRST 20 ROWS WITH TIES;

SELECT * FROM medir(:'top20');

\echo '-- (b) Vista materializada'
CREATE MATERIALIZED VIEW top_prestados AS
SELECT   l.isbn, l.titulo, count(*) AS prestamos
FROM     prestamo p
JOIN     ejemplar e ON e.id_ejemplar = p.id_ejemplar
JOIN     libro    l ON l.isbn = e.isbn
GROUP BY l.isbn, l.titulo
ORDER BY prestamos DESC
FETCH FIRST 20 ROWS WITH TIES;

EXPLAIN (ANALYZE, COSTS OFF) SELECT * FROM top_prestados;
SELECT * FROM medir('SELECT * FROM top_prestados');

SELECT * FROM top_prestados FETCH FIRST 3 ROWS ONLY;

-- Lo que cuesta un REFRESH: lo mismo que la consulta directa.
\timing on
REFRESH MATERIALIZED VIEW top_prestados;
\timing off

\echo '-- (c) Un mes de mucho movimiento del ejemplar 15000 (Libro 5000)'
SELECT count(*) AS prestamos_libro_5000_antes
FROM   prestamo p JOIN ejemplar e ON e.id_ejemplar = p.id_ejemplar
WHERE  e.isbn = '9780000005000';

INSERT INTO prestamo
SELECT 500000 + g, 15000, (1000000001 + g % 2000)::text,
       DATE '2025-06-01', DATE '2025-06-15', DATE '2025-06-10'
FROM   generate_series(1, 4000) AS g;

\echo '-- La vista materializada todavía no lo ve'
SELECT * FROM top_prestados FETCH FIRST 3 ROWS ONLY;
SELECT count(*) AS filas_de_libro_5000_en_la_vista
FROM   top_prestados WHERE isbn = '9780000005000';

\echo '-- La consulta directa sí'
SELECT * FROM (:top20) t FETCH FIRST 3 ROWS ONLY;

REFRESH MATERIALIZED VIEW top_prestados;

\echo '-- Después del REFRESH'
SELECT * FROM top_prestados FETCH FIRST 3 ROWS ONLY;

-- ---------------------------------------------------------------------
\echo
\echo '== A5. fecha_esperada: ¿derivada o histórica? =='
-- ---------------------------------------------------------------------

-- En los datos generados el plazo es siempre 14 días, así que aquí la
-- columna se podría calcular. Eso dicen los datos, no la regla del negocio.
SELECT fecha_esperada - fecha_prestamo AS plazo_dias, count(*) AS prestamos
FROM   prestamo
GROUP BY 1;
