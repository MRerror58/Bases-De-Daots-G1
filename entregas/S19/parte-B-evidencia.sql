-- =====================================================================
-- S19. Parte B: evidencia sobre el esquema del proyecto (biblioteca)
-- Grupo 1 - Proyecto Biblioteca
-- Integrantes:
--   Santiago Ruiz Vanegas         (202177804)
--   Juan David Vasquez Cañas      (2515123)
--   Omar Esteban Agredo Titimbo   (2516317)
--
-- Uso: docker compose exec postgres psql -U curso -d curso -e -f /scripts/parte-B-evidencia.sql
-- No cambia nada: son consultas o pruebas dentro de BEGIN ... ROLLBACK.
-- La tabla de resultados está en parte-B.md.
-- =====================================================================

\set ON_ERROR_STOP on
SET search_path TO biblioteca;

\echo
\echo '====== B1. usuario ======'

-- Las claves candidatas (id_usuario, nombre_usuario) no se repiten
SELECT nombre_usuario, count(*) FROM usuario GROUP BY 1 HAVING count(*) > 1;

-- nombre_usuario es una copia del documento del lector (redundancia entre tablas)
SELECT count(*) AS lectores,
       count(*) FILTER (WHERE u.nombre_usuario = l.documento) AS login_igual_a_documento
FROM lector l JOIN usuario u USING (id_usuario);

\echo
\echo '====== B2. lector ======'

-- Claves candidatas: id_lector, id_usuario, documento, correo (todas con UNIQUE)
SELECT conname, pg_get_constraintdef(oid)
FROM pg_constraint
WHERE conrelid = 'biblioteca.lector'::regclass AND contype IN ('p', 'u')
ORDER BY conname;

-- Correo repetido si se ignoran las mayúsculas (UNIQUE no lo atrapa)
SELECT lower(correo), count(*) FROM lector GROUP BY 1 HAVING count(*) > 1;

-- Dos banderas "activo" (lector y usuario) que se pueden contradecir
SELECT count(*) AS contradicciones_activo
FROM lector l JOIN usuario u USING (id_usuario)
WHERE l.activo <> u.activo;

BEGIN;
UPDATE usuario SET activo = false WHERE id_usuario = 1;
SELECT l.id_lector, l.activo AS lector_activo, u.activo AS usuario_activo
FROM lector l JOIN usuario u USING (id_usuario)
WHERE u.id_usuario = 1;    -- el esquema lo acepta: ¿el lector 1 está activo o no?
ROLLBACK;

\echo
\echo '====== B3. libro ======'

-- Texto repetido: categoría y autor
SELECT categoria, count(*) AS libros FROM libro GROUP BY 1 ORDER BY 2 DESC;
SELECT autor, count(*) AS libros FROM libro GROUP BY 1 HAVING count(*) > 1 ORDER BY 2 DESC;

-- Variantes de la misma categoría o autor (mayúsculas, espacios): hoy 0
SELECT lower(btrim(categoria)) AS categoria, count(DISTINCT categoria) AS variantes
FROM libro GROUP BY 1 HAVING count(DISTINCT categoria) > 1;
SELECT lower(btrim(autor)) AS autor, count(DISTINCT autor) AS variantes
FROM libro GROUP BY 1 HAVING count(DISTINCT autor) > 1;

-- Un libro con varios autores obliga a meter una lista en la celda (1FN)
BEGIN;
INSERT INTO libro (isbn, titulo, autor, categoria, anio_publicacion, ejemplares_disponibles)
VALUES ('9780073523323', 'Fundamentos de bases de datos',
        'Silberschatz, Korth, Sudarshan', 'Ciencia', 2019, 2);
SELECT count(*) AS libros_de_korth_con_like FROM libro WHERE autor LIKE '%Korth%';
SELECT isbn, autor FROM libro WHERE autor LIKE '%,%';   -- la lista quedó en una celda
ROLLBACK;

-- editorial: vacía en todos los libros (cuando se llene, será texto repetido)
SELECT count(*) AS libros, count(editorial) AS con_editorial FROM libro;

-- ejemplares_disponibles es un dato derivado (total - préstamos abiertos),
-- pero se guarda y nada lo actualiza: un préstamo no lo cambia
BEGIN;
SELECT isbn, ejemplares_disponibles AS antes FROM libro WHERE isbn = '9780000000003';
INSERT INTO prestamo (id_lector, isbn, registrado_por, fecha_prestamo, fecha_vencimiento)
SELECT id_lector, '9780000000003', 1, CURRENT_DATE, CURRENT_DATE + 15
FROM lector ORDER BY id_lector LIMIT 3;
SELECT l.isbn, l.ejemplares_disponibles AS despues_de_3_prestamos,
       count(p.id_prestamo) AS prestamos_abiertos
FROM libro l LEFT JOIN prestamo p ON p.isbn = l.isbn AND p.fecha_devolucion IS NULL
WHERE l.isbn = '9780000000003'
GROUP BY l.isbn, l.ejemplares_disponibles;   -- sigue en 2 con 3 prestados
ROLLBACK;

\echo
\echo '====== B4. prestamo ======'

-- Sin UNIQUE en la clave natural: el mismo préstamo se puede registrar dos veces
BEGIN;
INSERT INTO prestamo (id_lector, isbn, registrado_por, fecha_prestamo, fecha_vencimiento)
SELECT id_lector, '9780000000001', 1, CURRENT_DATE, CURRENT_DATE + 15
FROM lector ORDER BY id_lector LIMIT 1;
INSERT INTO prestamo (id_lector, isbn, registrado_por, fecha_prestamo, fecha_vencimiento)
SELECT id_lector, '9780000000001', 1, CURRENT_DATE, CURRENT_DATE + 15
FROM lector ORDER BY id_lector LIMIT 1;
SELECT id_lector, isbn, fecha_prestamo, count(*) AS veces
FROM prestamo
GROUP BY 1, 2, 3 HAVING count(*) > 1;   -- 1 fila: el duplicado se aceptó
ROLLBACK;

-- devuelto_por y fecha_devolucion se pueden contradecir
BEGIN;
INSERT INTO prestamo (id_lector, isbn, registrado_por, devuelto_por,
                      fecha_prestamo, fecha_vencimiento, fecha_devolucion)
SELECT id_lector, '9780000000002', 1, 2, CURRENT_DATE, CURRENT_DATE + 15, NULL
FROM lector ORDER BY id_lector LIMIT 1;
SELECT id_prestamo, devuelto_por, fecha_devolucion
FROM prestamo WHERE devuelto_por IS NOT NULL AND fecha_devolucion IS NULL;  -- se aceptó
ROLLBACK;

-- registrado_por debería ser un bibliotecario, pero la FK acepta cualquier usuario
SELECT rol, count(*) FROM usuario GROUP BY rol;   -- hoy solo hay lectores

-- El estado del préstamo NO se guarda: se calcula (bien)
SELECT column_name FROM information_schema.columns
WHERE table_schema = 'biblioteca' AND table_name = 'prestamo'
ORDER BY ordinal_position;

\echo
\echo '====== B5. tablas auxiliares de la carga (rechazo_carga, stg_*) ======'

SELECT c.relname AS tabla,
       EXISTS (SELECT 1 FROM pg_constraint k
               WHERE k.conrelid = c.oid AND k.contype = 'p') AS tiene_pk
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'biblioteca' AND c.relkind = 'r'
  AND (c.relname LIKE 'stg_%' OR c.relname = 'rechazo_carga')
ORDER BY 1;
