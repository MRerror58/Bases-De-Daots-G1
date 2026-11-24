-- ============================================================
-- carga-prestamos.sql  (PostgreSQL 16)
-- Proyecto Biblioteca - Grupo 1
--
-- Datos propios de prestamos para que los 4 reportes del Hito 2
-- devuelvan filas. Antes de esto la tabla prestamo estaba vacia.
--
-- Que hace:
--   1. Crea dos usuarios con rol 'bibliotecario' (biblio01, biblio02)
--      porque prestamo.registrado_por es NOT NULL y hasta ahora solo
--      existian usuarios con rol 'lector'.
--   2. Borra los prestamos de la demo y los vuelve a insertar con
--      fechas relativas a CURRENT_DATE, para que la mora sea siempre
--      la misma sin importar el dia en que se corra.
--   3. Ajusta libro.ejemplares_disponibles: resta 1 por cada prestamo
--      abierto y lo devuelve al re-ejecutar (script idempotente).
--
-- Requiere que carga-libros.sql y carga-lectores.sql ya se hayan
-- corrido (necesita los 37 libros y los 20 lectores).
--
-- Uso:
--   docker compose exec -T postgres psql -U curso -d curso \
--     -f /scripts/carga-prestamos.sql
--
-- Se puede correr cuantas veces se quiera: el resultado es el mismo.
-- ============================================================

\set ON_ERROR_STOP on

CREATE EXTENSION IF NOT EXISTS pgcrypto SCHEMA public;

SET search_path TO biblioteca, public;

BEGIN;

-- ------------------------------------------------------------
-- 1. Bibliotecarios de demostracion
--    Contrasena inicial = el mismo nombre de usuario (bcrypt).
-- ------------------------------------------------------------
INSERT INTO usuario (nombre_usuario, contrasena_hash, rol)
VALUES
    ('biblio01', crypt('biblio01', gen_salt('bf')), 'bibliotecario'),
    ('biblio02', crypt('biblio02', gen_salt('bf')), 'bibliotecario')
ON CONFLICT (nombre_usuario) DO NOTHING;

-- ------------------------------------------------------------
-- 2. Deshacer la demo anterior (si existe)
-- ------------------------------------------------------------
-- Primero devolver los ejemplares que descontaban los prestamos
-- abiertos de la corrida anterior; si no, cada re-ejecucion
-- dejaria los libros con menos copias de las reales.
UPDATE libro l
SET ejemplares_disponibles = ejemplares_disponibles + x.cuantos
FROM (
    SELECT p.isbn, count(*) AS cuantos
    FROM prestamo p
    JOIN usuario u ON u.id_usuario = p.registrado_por
    WHERE u.nombre_usuario IN ('biblio01', 'biblio02')
      AND p.fecha_devolucion IS NULL
    GROUP BY p.isbn
) x
WHERE l.isbn = x.isbn;

DELETE FROM prestamo
WHERE registrado_por IN (
    SELECT id_usuario FROM usuario
    WHERE nombre_usuario IN ('biblio01', 'biblio02')
);

-- ------------------------------------------------------------
-- 3. Prestamos de demostracion
--
--    dias_prestamo    : hace cuantos dias se presto
--    dias_devolucion  : hace cuantos dias se devolvio
--                       (NULL = prestamo abierto)
--    El vencimiento se calcula a 14 dias del prestamo, asi que
--    un prestamo abierto con dias_prestamo > 14 esta en mora.
--
--    Reparto buscado:
--      - 9 devueltos  -> Reporte 2 (mas libros leidos)
--      - 4 abiertos y vencidos -> Reportes 3 y 4 (morosos / notificacion)
--      - 2 abiertos vigentes -> control (no deben salir en mora)
-- ------------------------------------------------------------
INSERT INTO prestamo (
    id_lector,
    isbn,
    registrado_por,
    devuelto_por,
    fecha_prestamo,
    fecha_vencimiento,
    fecha_devolucion
)
SELECT
    le.id_lector,
    v.isbn,
    bib.id_usuario,
    CASE WHEN v.dias_devolucion IS NULL THEN NULL ELSE bib2.id_usuario END,
    CURRENT_DATE - v.dias_prestamo,
    CURRENT_DATE - v.dias_prestamo + 14,
    CASE
        WHEN v.dias_devolucion IS NULL THEN NULL
        ELSE CURRENT_DATE - v.dias_devolucion
    END
FROM (VALUES
    -- documento,   isbn,           dias_prestamo, dias_devolucion
    -- --- devueltos (Reporte 2) ---
    ('1000000001', '9780000000001', 60, 45),
    ('1000000001', '9780000000004', 55, 40),
    ('1000000001', '9780000000007', 50, 30),
    ('1000000002', '9780000000002', 60, 46),
    ('1000000002', '9780000000006', 58, 44),
    ('1000000002', '9780000000009', 45, 31),
    ('1000000003', '9780000000011', 40, 28),
    ('1000000003', '9780000000012', 35, 21),
    ('1000000004', '9780000000013', 30, 16),
    -- --- abiertos y vencidos (Reportes 3 y 4) ---
    ('1000000004', '9780000000007', 40, NULL),   -- 26 dias de mora
    ('1000000004', '9780000000001', 20, NULL),   --  6 dias de mora
    ('1000000003', '9780000000010', 30, NULL),   -- 16 dias de mora
    ('1000000005', '9780000000005', 16, NULL),   --  2 dias de mora
    -- --- abiertos vigentes (no deben salir en mora) ---
    ('1000000011', '9780000000014',  3, NULL),
    ('1000000008', '9780000000022',  7, NULL)
) AS v (documento, isbn, dias_prestamo, dias_devolucion)
JOIN lector le ON le.documento = v.documento
JOIN libro l ON l.isbn = v.isbn
CROSS JOIN (SELECT id_usuario FROM usuario WHERE nombre_usuario = 'biblio01') bib
CROSS JOIN (SELECT id_usuario FROM usuario WHERE nombre_usuario = 'biblio02') bib2;

-- ------------------------------------------------------------
-- 4. Descontar el ejemplar de cada prestamo abierto
--    (un ejemplar por libro en esta demo: cada ISBN abierto
--    aparece una sola vez, y todos arrancan con 2 o mas copias)
-- ------------------------------------------------------------
UPDATE libro l
SET ejemplares_disponibles = ejemplares_disponibles - x.cuantos
FROM (
    SELECT p.isbn, count(*) AS cuantos
    FROM prestamo p
    JOIN usuario u ON u.id_usuario = p.registrado_por
    WHERE u.nombre_usuario IN ('biblio01', 'biblio02')
      AND p.fecha_devolucion IS NULL
    GROUP BY p.isbn
) x
WHERE l.isbn = x.isbn;

-- ------------------------------------------------------------
-- 5. Resumen de lo que quedo cargado
-- ------------------------------------------------------------
SELECT
    count(*)                                                  AS prestamos,
    count(*) FILTER (WHERE fecha_devolucion IS NOT NULL)      AS devueltos,
    count(*) FILTER (WHERE fecha_devolucion IS NULL)           AS abiertos,
    count(*) FILTER (
        WHERE fecha_devolucion IS NULL
          AND fecha_vencimiento < CURRENT_DATE
    )                                                          AS en_mora
FROM prestamo;

COMMIT;
