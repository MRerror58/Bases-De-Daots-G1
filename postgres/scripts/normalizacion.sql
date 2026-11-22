-- =====================================================================
-- S20, Hito 3: migración del esquema biblioteca al esquema normalizado
-- Grupo 1 - Proyecto Biblioteca
-- Integrantes:
--   Santiago Ruiz Vanegas         (202177804)
--   Juan David Vasquez Cañas      (2515123)
--   Omar Esteban Agredo Titimbo   (2516317)
--
-- Lleva una base con el esquema de S14/S16 (libro con autor, categoria,
-- editorial y ejemplares_disponibles; préstamo por ISBN) al esquema de
-- postgres/init/01_esquema.sql, conservando los datos.
--
-- Uso (desde entorno-docker/, con este archivo en postgres/scripts/):
--   docker compose exec postgres psql -U curso -d curso -f /scripts/normalizacion.sql
--
-- Todo va en una transacción: si una verificación falla, no queda nada a
-- medias. Si la base ya está migrada, se detiene sin tocar nada.
-- =====================================================================

\set ON_ERROR_STOP on
SET search_path TO biblioteca, public;

-- Si libro ya no tiene la columna autor, la migración ya se hizo.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                   WHERE table_schema = 'biblioteca'
                     AND table_name = 'libro' AND column_name = 'autor') THEN
        RAISE EXCEPTION 'La base ya tiene el esquema normalizado: no hay nada que migrar.';
    END IF;
END;
$$;

-- ---------------------------------------------------------------------
\echo
\echo '== 1. Evidencia antes del cambio =='
-- ---------------------------------------------------------------------

SELECT (SELECT count(*) FROM libro)                       AS libros,
       (SELECT sum(ejemplares_disponibles) FROM libro)    AS ejemplares_declarados,
       (SELECT count(*) FROM lector)                      AS lectores,
       (SELECT count(*) FROM usuario)                     AS usuarios,
       (SELECT count(*) FROM prestamo)                    AS prestamos,
       (SELECT count(*) FROM prestamo
        WHERE fecha_devolucion IS NULL)                   AS prestamos_abiertos;

-- Texto repetido: categorías y autores escritos una vez por libro.
SELECT categoria, count(*) AS libros FROM libro GROUP BY categoria ORDER BY libros DESC, categoria;
SELECT autor, count(*) AS libros FROM libro GROUP BY autor HAVING count(*) > 1 ORDER BY libros DESC, autor;

-- Lo que las restricciones nuevas rechazarían. Si alguna da más de 0,
-- la migración aborta en el ALTER correspondiente: hay que limpiar antes.
SELECT (SELECT count(*) FROM (SELECT 1 FROM prestamo
                              GROUP BY id_lector, isbn, fecha_prestamo
                              HAVING count(*) > 1) d)            AS prestamos_duplicados,
       (SELECT count(*) FROM prestamo
        WHERE (devuelto_por IS NULL) <> (fecha_devolucion IS NULL)) AS devoluciones_a_medias,
       (SELECT count(*) FROM (SELECT 1 FROM lector
                              GROUP BY lower(correo)
                              HAVING count(*) > 1) c)            AS correos_repetidos_sin_mayusculas;

BEGIN;

-- Copias para comparar al final.
CREATE TEMP TABLE libro_antes    ON COMMIT DROP AS SELECT * FROM libro;
CREATE TEMP TABLE prestamo_antes ON COMMIT DROP AS SELECT * FROM prestamo;

-- ---------------------------------------------------------------------
\echo
\echo '== 2. Catálogos: categoria, autor, editorial =='
-- ---------------------------------------------------------------------

CREATE TABLE categoria (
    id_categoria  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nombre        varchar(40) NOT NULL UNIQUE
                  CHECK (btrim(nombre) <> '')
);

INSERT INTO categoria (nombre)
SELECT DISTINCT categoria FROM libro ORDER BY categoria;

CREATE TABLE autor (
    id_autor  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nombre    varchar(120) NOT NULL UNIQUE
              CHECK (btrim(nombre) <> '')
);

-- Hoy cada libro tiene un solo autor. Si alguno trajera varios separados
-- por ";", aquí ya se separan.
INSERT INTO autor (nombre)
SELECT DISTINCT btrim(a)
FROM   libro, regexp_split_to_table(autor, ';') AS a
WHERE  btrim(a) <> ''
ORDER BY 1;

CREATE TABLE editorial (
    id_editorial  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nombre        varchar(120) NOT NULL UNIQUE
                  CHECK (btrim(nombre) <> '')
);

INSERT INTO editorial (nombre)
SELECT DISTINCT btrim(editorial) FROM libro
WHERE  editorial IS NOT NULL AND btrim(editorial) <> ''
ORDER BY 1;

CREATE TABLE libro_autor (
    isbn      varchar(13) NOT NULL,
    id_autor  integer NOT NULL,

    PRIMARY KEY (isbn, id_autor),

    CONSTRAINT fk_libro_autor_libro
        FOREIGN KEY (isbn)
        REFERENCES libro(isbn),

    CONSTRAINT fk_libro_autor_autor
        FOREIGN KEY (id_autor)
        REFERENCES autor(id_autor)
);

INSERT INTO libro_autor (isbn, id_autor)
SELECT DISTINCT l.isbn, au.id_autor
FROM   libro l, regexp_split_to_table(l.autor, ';') AS a
JOIN   autor au ON au.nombre = btrim(a);

ALTER TABLE libro ADD COLUMN id_categoria integer,
                  ADD COLUMN id_editorial integer;

UPDATE libro l SET id_categoria = c.id_categoria
FROM   categoria c WHERE c.nombre = l.categoria;

UPDATE libro l SET id_editorial = e.id_editorial
FROM   editorial e WHERE e.nombre = btrim(l.editorial);

ALTER TABLE libro
    ALTER COLUMN id_categoria SET NOT NULL,
    ADD CONSTRAINT fk_libro_categoria
        FOREIGN KEY (id_categoria) REFERENCES categoria(id_categoria),
    ADD CONSTRAINT fk_libro_editorial
        FOREIGN KEY (id_editorial) REFERENCES editorial(id_editorial);

-- ---------------------------------------------------------------------
\echo
\echo '== 3. Ejemplares y préstamo por ejemplar =='
-- ---------------------------------------------------------------------

CREATE TABLE ejemplar (
    id_ejemplar  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    isbn         varchar(13) NOT NULL,
    activo       boolean NOT NULL DEFAULT true,

    CONSTRAINT fk_ejemplar_libro
        FOREIGN KEY (isbn)
        REFERENCES libro(isbn)
);

-- ejemplares_disponibles nunca se descontó al prestar (S19, evidencia B3):
-- es el número de copias que llegó en la carga. Por si alguien lo hubiera
-- bajado a mano, se crean al menos tantas copias como préstamos abiertos.
INSERT INTO ejemplar (isbn)
SELECT l.isbn
FROM   libro l
CROSS JOIN LATERAL generate_series(1, greatest(
           l.ejemplares_disponibles,
           (SELECT count(*) FROM prestamo p
            WHERE p.isbn = l.isbn AND p.fecha_devolucion IS NULL))) AS g
ORDER BY l.isbn, g;

ALTER TABLE prestamo ADD COLUMN id_ejemplar integer;

-- Préstamos abiertos: el n-ésimo préstamo abierto de un ISBN se asigna a su
-- n-ésimo ejemplar, para que ninguna copia quede prestada dos veces.
UPDATE prestamo p SET id_ejemplar = x.id_ejemplar
FROM (SELECT a.id_prestamo, e.id_ejemplar
      FROM  (SELECT id_prestamo, isbn,
                    row_number() OVER (PARTITION BY isbn ORDER BY id_prestamo) AS n
             FROM   prestamo WHERE fecha_devolucion IS NULL) a
      JOIN  (SELECT id_ejemplar, isbn,
                    row_number() OVER (PARTITION BY isbn ORDER BY id_ejemplar) AS n
             FROM   ejemplar) e ON e.isbn = a.isbn AND e.n = a.n) x
WHERE p.id_prestamo = x.id_prestamo;

-- Préstamos devueltos: el esquema viejo no guardaba qué copia salió. Se
-- asignan a la primera copia del libro, lo único que se puede afirmar.
UPDATE prestamo p SET id_ejemplar =
       (SELECT min(e.id_ejemplar) FROM ejemplar e WHERE e.isbn = p.isbn)
WHERE  p.fecha_devolucion IS NOT NULL;

ALTER TABLE prestamo
    ALTER COLUMN id_ejemplar SET NOT NULL,
    ADD CONSTRAINT fk_prestamo_ejemplar
        FOREIGN KEY (id_ejemplar) REFERENCES ejemplar(id_ejemplar),
    ADD CONSTRAINT uq_prestamo_natural
        UNIQUE (id_lector, id_ejemplar, fecha_prestamo),
    ADD CONSTRAINT chk_devolucion_completa
        CHECK ((devuelto_por IS NULL) = (fecha_devolucion IS NULL));

CREATE UNIQUE INDEX prestamo_abierto_key ON prestamo (id_ejemplar)
    WHERE fecha_devolucion IS NULL;

CREATE INDEX ejemplar_isbn_idx      ON ejemplar (isbn);
CREATE INDEX libro_autor_autor_idx  ON libro_autor (id_autor);
CREATE INDEX prestamo_lector_idx    ON prestamo (id_lector);

-- ---------------------------------------------------------------------
\echo
\echo '== 4. lector: correo único sin distinguir mayúsculas =='
-- ---------------------------------------------------------------------

ALTER TABLE lector DROP CONSTRAINT lector_correo_key;
CREATE UNIQUE INDEX lector_correo_lower_key ON lector (lower(correo));

COMMENT ON COLUMN usuario.nombre_usuario IS
    'Login de la cuenta. La carga inicial usa el documento del lector, pero es un dato propio de la cuenta: cambiarlo no cambia el documento, ni al revés.';
COMMENT ON COLUMN usuario.activo IS
    'La cuenta puede iniciar sesión.';
COMMENT ON COLUMN lector.activo IS
    'El lector puede pedir préstamos. Es independiente de usuario.activo: un lector suspendido puede seguir entrando a consultar su historial.';

-- ---------------------------------------------------------------------
\echo
\echo '== 5. Vistas de lo derivado =='
-- ---------------------------------------------------------------------

CREATE VIEW libro_disponibilidad AS
SELECT   l.isbn,
         l.titulo,
         count(e.id_ejemplar)                    AS ejemplares,
         count(p.id_prestamo)                    AS prestados,
         count(e.id_ejemplar) - count(p.id_prestamo) AS disponibles
FROM     libro l
LEFT JOIN ejemplar e  ON e.isbn = l.isbn AND e.activo
LEFT JOIN prestamo p  ON p.id_ejemplar = e.id_ejemplar
                     AND p.fecha_devolucion IS NULL
GROUP BY l.isbn, l.titulo;

CREATE VIEW libro_detalle AS
SELECT   l.isbn,
         l.titulo,
         string_agg(a.nombre, '; ' ORDER BY a.nombre) AS autores,
         c.nombre                                      AS categoria,
         ed.nombre                                     AS editorial,
         l.anio_publicacion,
         l.activo
FROM     libro l
JOIN     categoria c        ON c.id_categoria = l.id_categoria
LEFT JOIN editorial ed      ON ed.id_editorial = l.id_editorial
LEFT JOIN libro_autor la    ON la.isbn = l.isbn
LEFT JOIN autor a           ON a.id_autor = la.id_autor
GROUP BY l.isbn, l.titulo, c.nombre, ed.nombre, l.anio_publicacion, l.activo;

-- ---------------------------------------------------------------------
\echo
\echo '== 6. Verificación (antes de borrar las columnas viejas) =='
-- ---------------------------------------------------------------------

SELECT (SELECT count(*) FROM libro_antes)    AS libros_antes,
       (SELECT count(*) FROM libro)          AS libros_despues,
       (SELECT sum(ejemplares_disponibles) FROM libro_antes) AS ejemplares_declarados,
       (SELECT count(*) FROM ejemplar)       AS ejemplares_creados,
       (SELECT count(*) FROM prestamo_antes) AS prestamos_antes,
       (SELECT count(*) FROM prestamo)       AS prestamos_despues,
       (SELECT count(*) FROM categoria)      AS categorias,
       (SELECT count(*) FROM autor)          AS autores,
       (SELECT count(*) FROM libro_autor)    AS libro_autor,
       (SELECT count(*) FROM editorial)      AS editoriales;

\echo '-- Libros que cambiaron (antes EXCEPT después y al revés): deben ser 0 filas'
SELECT isbn, titulo, autor, categoria, editorial, anio_publicacion, activo FROM libro_antes
EXCEPT
SELECT isbn, titulo, autores, categoria, editorial, anio_publicacion, activo FROM libro_detalle;

SELECT isbn, titulo, autores, categoria, editorial, anio_publicacion, activo FROM libro_detalle
EXCEPT
SELECT isbn, titulo, autor, categoria, editorial, anio_publicacion, activo FROM libro_antes;

\echo '-- Préstamos que cambiaron de libro, lector o fechas: deben ser 0 filas'
SELECT id_prestamo, id_lector, isbn, fecha_prestamo, fecha_vencimiento, fecha_devolucion
FROM   prestamo_antes
EXCEPT
SELECT p.id_prestamo, p.id_lector, e.isbn, p.fecha_prestamo, p.fecha_vencimiento, p.fecha_devolucion
FROM   prestamo p JOIN ejemplar e ON e.id_ejemplar = p.id_ejemplar;

\echo '-- Libros con menos copias de las declaradas: deben ser 0 filas'
SELECT la.isbn, la.ejemplares_disponibles, d.ejemplares
FROM   libro_antes la JOIN libro_disponibilidad d ON d.isbn = la.isbn
WHERE  d.ejemplares < la.ejemplares_disponibles;

-- Si algo no cuadra, se aborta toda la transacción.
DO $$
BEGIN
    IF (SELECT count(*) FROM libro) <> (SELECT count(*) FROM libro_antes)
       OR (SELECT count(*) FROM prestamo) <> (SELECT count(*) FROM prestamo_antes)
       OR EXISTS (SELECT isbn, titulo, autor, categoria, editorial, anio_publicacion, activo FROM libro_antes
                  EXCEPT
                  SELECT isbn, titulo, autores, categoria, editorial, anio_publicacion, activo FROM libro_detalle)
       OR EXISTS (SELECT id_prestamo, id_lector, isbn FROM prestamo_antes
                  EXCEPT
                  SELECT p.id_prestamo, p.id_lector, e.isbn
                  FROM prestamo p JOIN ejemplar e ON e.id_ejemplar = p.id_ejemplar)
    THEN
        RAISE EXCEPTION 'La verificación de la migración falló: se deshace todo.';
    END IF;
END;
$$;

-- ---------------------------------------------------------------------
\echo
\echo '== 7. Quitar lo viejo =='
-- ---------------------------------------------------------------------

-- Las vistas no usan estas columnas, así que se pueden borrar sin CASCADE.
ALTER TABLE prestamo DROP CONSTRAINT fk_prestamo_libro,
                     DROP COLUMN isbn;

ALTER TABLE libro DROP COLUMN autor,
                  DROP COLUMN categoria,
                  DROP COLUMN editorial,
                  DROP COLUMN ejemplares_disponibles;

-- Columnas en el mismo orden que en 01_esquema.sql, aunque aquí id_ejemplar
-- haya quedado al final de la tabla.
CREATE VIEW prestamo_estado AS
SELECT p.id_prestamo, p.id_lector, p.id_ejemplar, p.registrado_por, p.devuelto_por,
       p.fecha_prestamo, p.fecha_vencimiento, p.fecha_devolucion,
       CASE
           WHEN p.fecha_devolucion IS NOT NULL        THEN 'devuelto'
           WHEN p.fecha_vencimiento < CURRENT_DATE    THEN 'vencido'
           ELSE 'activo'
       END AS estado
FROM   prestamo p;

COMMIT;

-- ---------------------------------------------------------------------
\echo
\echo '== 8. Después =='
-- ---------------------------------------------------------------------

SELECT * FROM libro_detalle ORDER BY isbn FETCH FIRST 5 ROWS ONLY;
SELECT * FROM libro_disponibilidad ORDER BY isbn FETCH FIRST 5 ROWS ONLY;
SELECT estado, count(*) AS prestamos FROM prestamo_estado GROUP BY estado ORDER BY estado;
