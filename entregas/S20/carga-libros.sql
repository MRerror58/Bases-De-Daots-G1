-- Carga de libros desde CSV al esquema biblioteca (S14, Grupo 1)
-- Patrón: tabla de paso -> validación -> tabla final -> bitácora, en una transacción.
-- Actualizada en S20 para el esquema normalizado: cada fila válida llena
-- libro, categoria y autor (si son nuevos), libro_autor y una fila de
-- ejemplar por cada copia. Varios autores van separados por ";" en la columna autor.
--
-- Uso (desde entorno-docker/, con los CSV en postgres/scripts/datos/):
--   docker compose exec postgres psql -U curso -d curso \
--     -v archivo=/scripts/datos/libros_semilla_con_errores.csv \
--     -f /scripts/carga-libros.sql
--
-- Sin "-v archivo=..." carga /scripts/datos/libros_semilla.csv.
-- Repetir la carga no duplica nada: un ISBN que ya está se rechaza.

\set ON_ERROR_STOP on
\if :{?archivo}
\else
    \set archivo /scripts/datos/libros_semilla.csv
\endif

SET search_path TO biblioteca, public;

BEGIN;

TRUNCATE stg_linea, stg_libro RESTART IDENTITY;

-- FORMAT text funciona porque el CSV no contiene tabuladores.
COPY stg_linea (linea) FROM :'archivo' WITH (FORMAT text);
DELETE FROM stg_linea WHERE n = 1;          -- encabezado

INSERT INTO stg_libro (linea_csv, contenido, num_campos, isbn, titulo, autor,
                       categoria, anio_publicacion, ejemplares_disponibles)
SELECT n, linea,
       array_length(string_to_array(linea, ','), 1),
       trim(split_part(linea, ',', 1)),
       trim(split_part(linea, ',', 2)),
       trim(split_part(linea, ',', 3)),
       trim(split_part(linea, ',', 4)),
       trim(split_part(linea, ',', 5)),
       trim(split_part(linea, ',', 6))
FROM stg_linea;

-- El orden importa: cada ::integer va después de la regex que comprueba que son dígitos.
UPDATE stg_libro SET motivo = CASE
    WHEN num_campos <> 6                          THEN 'tiene ' || num_campos || ' columnas, se esperaban 6'
    WHEN isbn = ''                                THEN 'isbn vacío'
    WHEN isbn !~ '^[0-9]{13}$'                    THEN 'isbn no tiene 13 dígitos'
    WHEN titulo = ''                              THEN 'título vacío'
    WHEN length(titulo) > 200                     THEN 'título de más de 200 caracteres'
    WHEN autor = ''                               THEN 'autor vacío'
    WHEN EXISTS (SELECT 1 FROM regexp_split_to_table(autor, ';') AS a
                 WHERE btrim(a) = '')             THEN 'autor vacío en la lista de autores'
    WHEN EXISTS (SELECT 1 FROM regexp_split_to_table(autor, ';') AS a
                 WHERE length(btrim(a)) > 120)    THEN 'autor de más de 120 caracteres'
    WHEN categoria = ''                           THEN 'categoría vacía'
    WHEN length(categoria) > 40                   THEN 'categoría de más de 40 caracteres'
    WHEN anio_publicacion !~ '^[0-9]{1,4}$'       THEN 'año no numérico'
    WHEN anio_publicacion::integer NOT BETWEEN 1450 AND 2100
                                                  THEN 'año fuera de rango'
    WHEN anio_publicacion::integer > extract(year FROM current_date)
                                                  THEN 'año en el futuro'
    WHEN ejemplares_disponibles !~ '^-?[0-9]{1,6}$'
                                                  THEN 'ejemplares no numérico'
    WHEN ejemplares_disponibles::integer < 0      THEN 'ejemplares negativo'
    WHEN EXISTS (SELECT 1 FROM libro l WHERE l.isbn = stg_libro.isbn)
                                                  THEN 'isbn ya existe en el catálogo'
END;

-- Duplicados dentro del archivo: se conserva la primera aparición.
UPDATE stg_libro SET motivo = 'isbn repetido en el archivo (línea '
       || (SELECT min(s2.linea_csv) FROM stg_libro s2
           WHERE s2.isbn = stg_libro.isbn AND s2.motivo IS NULL) || ')'
WHERE motivo IS NULL
  AND EXISTS (SELECT 1 FROM stg_libro s2
              WHERE s2.isbn = stg_libro.isbn
                AND s2.motivo IS NULL
                AND s2.linea_csv < stg_libro.linea_csv);

-- Catálogos primero: solo los nombres que todavía no existen.
INSERT INTO categoria (nombre)
SELECT DISTINCT categoria FROM stg_libro
WHERE  motivo IS NULL
ON CONFLICT (nombre) DO NOTHING;

INSERT INTO autor (nombre)
SELECT DISTINCT btrim(a)
FROM   stg_libro, regexp_split_to_table(autor, ';') AS a
WHERE  motivo IS NULL
ON CONFLICT (nombre) DO NOTHING;

INSERT INTO libro (isbn, titulo, id_categoria, anio_publicacion)
SELECT s.isbn, s.titulo, c.id_categoria, s.anio_publicacion::smallint
FROM   stg_libro s
JOIN   categoria c ON c.nombre = s.categoria
WHERE  s.motivo IS NULL;

INSERT INTO libro_autor (isbn, id_autor)
SELECT DISTINCT s.isbn, au.id_autor
FROM   stg_libro s, regexp_split_to_table(s.autor, ';') AS a
JOIN   autor au ON au.nombre = btrim(a)
WHERE  s.motivo IS NULL;

-- El CSV trae cuántas copias llegan; cada una es un ejemplar.
INSERT INTO ejemplar (isbn)
SELECT s.isbn
FROM   stg_libro s
CROSS JOIN LATERAL generate_series(1, s.ejemplares_disponibles::integer) AS g
WHERE  s.motivo IS NULL
ORDER BY s.linea_csv, g;

INSERT INTO rechazo_carga (archivo, linea, contenido, motivo)
SELECT :'archivo', linea_csv, contenido, motivo
FROM stg_libro
WHERE motivo IS NOT NULL;

COMMIT;

SELECT count(*) FILTER (WHERE motivo IS NULL)     AS cargadas,
       count(*) FILTER (WHERE motivo IS NOT NULL) AS rechazadas
FROM stg_libro;

SELECT linea_csv AS linea, motivo, contenido
FROM stg_libro
WHERE motivo IS NOT NULL
ORDER BY linea_csv;
