-- =====================================================================
-- S20, Hito 3: lo que S19 encontró, probado contra el esquema normalizado
-- Grupo 1 - Proyecto Biblioteca
--
-- Uso: docker compose exec postgres psql -U curso -d curso -f /scripts/pruebas-restricciones.sql
-- Requiere el esquema normalizado y las cargas de S14. Todo va dentro de
-- BEGIN ... ROLLBACK: la base queda como estaba.
--
-- Cada prueba intenta lo que en S19 se aceptó. intentar() ejecuta la
-- sentencia y dice qué restricción la rechazó, o "ACEPTADA" si pasó.
-- =====================================================================

\set ON_ERROR_STOP on
SET search_path TO biblioteca, public;

BEGIN;

CREATE FUNCTION pg_temp.intentar(prueba text, sentencia text)
RETURNS TABLE (caso text, resultado text)
LANGUAGE plpgsql AS $$
BEGIN
    caso := prueba;
    BEGIN
        EXECUTE sentencia;
        resultado := 'ACEPTADA';
    EXCEPTION WHEN others THEN
        GET STACKED DIAGNOSTICS resultado = CONSTRAINT_NAME;
        resultado := 'rechazada por ' || coalesce(nullif(resultado, ''), SQLERRM);
    END;
    RETURN NEXT;
END;
$$;

INSERT INTO usuario (nombre_usuario, contrasena_hash, rol)
VALUES ('bibliotecario.prueba', 'hash-de-prueba', 'bibliotecario');

-- Un préstamo abierto válido del primer ejemplar de Crónica de una muerte
-- anunciada (2 ejemplares), del lector 1000000001.
INSERT INTO prestamo (id_lector, id_ejemplar, registrado_por, fecha_prestamo, fecha_vencimiento)
SELECT l.id_lector, (SELECT min(id_ejemplar) FROM ejemplar WHERE isbn = '9780000000003'),
       u.id_usuario, CURRENT_DATE, CURRENT_DATE + 14
FROM   lector l, usuario u
WHERE  l.documento = '1000000001' AND u.nombre_usuario = 'bibliotecario.prueba';

\echo '== Lo que el esquema de S19 aceptaba (pruebas B2, B3 y B4) =='

SELECT * FROM pg_temp.intentar(
  'B4: el mismo préstamo dos veces (lector, ejemplar, fecha)',
  $q$INSERT INTO prestamo (id_lector, id_ejemplar, registrado_por, fecha_prestamo, fecha_vencimiento)
     SELECT id_lector, id_ejemplar, registrado_por, fecha_prestamo, fecha_vencimiento
     FROM prestamo$q$)
UNION ALL
SELECT * FROM pg_temp.intentar(
  'B4 bis: el mismo ejemplar prestado a otro lector mientras sigue afuera',
  $q$INSERT INTO prestamo (id_lector, id_ejemplar, registrado_por, fecha_prestamo, fecha_vencimiento)
     SELECT (SELECT id_lector FROM lector WHERE documento = '1000000002'),
            id_ejemplar, registrado_por, fecha_prestamo, fecha_vencimiento
     FROM prestamo$q$)
UNION ALL
SELECT * FROM pg_temp.intentar(
  'B4: devuelto_por sin fecha_devolucion',
  $q$UPDATE prestamo SET devuelto_por = registrado_por$q$)
UNION ALL
SELECT * FROM pg_temp.intentar(
  'B2: el mismo correo con otras mayúsculas',
  $q$WITH u AS (INSERT INTO usuario (nombre_usuario, contrasena_hash, rol)
               VALUES ('9999999999', 'x', 'lector') RETURNING id_usuario)
     INSERT INTO lector (id_usuario, documento, nombres, apellidos, correo)
     SELECT id_usuario, '9999999999', 'Prueba', 'Mayúsculas', 'Mariana.Gomez@Correo-Ejemplo.edu.co'
     FROM u$q$)
UNION ALL
SELECT * FROM pg_temp.intentar(
  'B3: libro con una categoría escrita de otra forma (sin catálogo)',
  $q$INSERT INTO libro (isbn, titulo, id_categoria, anio_publicacion)
     VALUES ('9780000000999', 'Prueba', 99, 2000)$q$);

\echo '== B3: el segundo ejemplar de Crónica sí se puede prestar, y los disponibles bajan solos =='

INSERT INTO prestamo (id_lector, id_ejemplar, registrado_por, fecha_prestamo, fecha_vencimiento)
SELECT l.id_lector, (SELECT max(id_ejemplar) FROM ejemplar WHERE isbn = '9780000000003'),
       u.id_usuario, CURRENT_DATE, CURRENT_DATE + 14
FROM   lector l, usuario u
WHERE  l.documento = '1000000002' AND u.nombre_usuario = 'bibliotecario.prueba';

SELECT * FROM libro_disponibilidad WHERE isbn = '9780000000003';

\echo '== B3: un libro con tres autores ya no es una lista en una celda =='

INSERT INTO autor (nombre) VALUES ('Abraham Silberschatz'), ('Henry F. Korth'), ('S. Sudarshan');
INSERT INTO libro (isbn, titulo, id_categoria, anio_publicacion)
SELECT '9780000000998', 'Fundamentos de bases de datos', id_categoria, 2014
FROM   categoria WHERE nombre = 'Ciencia';
INSERT INTO libro_autor (isbn, id_autor)
SELECT '9780000000998', id_autor FROM autor
WHERE  nombre IN ('Abraham Silberschatz', 'Henry F. Korth', 'S. Sudarshan');

SELECT isbn, titulo, autores, categoria FROM libro_detalle WHERE isbn = '9780000000998';

-- La búsqueda por autor ya es una igualdad, no un LIKE sobre una lista.
SELECT l.titulo
FROM   autor a JOIN libro_autor la USING (id_autor) JOIN libro l USING (isbn)
WHERE  a.nombre = 'Henry F. Korth';

ROLLBACK;
