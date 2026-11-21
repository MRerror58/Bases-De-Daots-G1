-- =====================================================================
-- S16. Hito 2: los cuatro reportes del proyecto sobre el esquema biblioteca
-- Grupo 1 - Proyecto Biblioteca
-- Integrantes:
--   Santiago Ruiz Vanegas         (202177804)
--   Juan David Vasquez Cañas      (2515123)
--   Omar Esteban Agredo Titimbo   (2516317)
--
-- Requiere el esquema (01_esquema.sql) y las dos cargas de S14
-- (carga-libros.sql y carga-lectores.sql): 32 libros y 20 lectores.
--
-- Uso (desde entorno-docker/, con este archivo en postgres/scripts/):
--   docker compose exec postgres psql -U curso -d curso -f /scripts/reportes.sql
--
-- Los préstamos de prueba se insertan dentro de BEGIN ... ROLLBACK: los
-- reportes corren sobre ellos y la base queda como estaba. Las fechas parten
-- de CURRENT_DATE, así que la mora sale igual cualquier día.
-- =====================================================================

\set ON_ERROR_STOP on
SET search_path TO biblioteca;

BEGIN;

-- El préstamo lo registra un usuario bibliotecario; la carga de S14 solo creó
-- cuentas de lectores. La contraseña es un hash bcrypt de ejemplo.
INSERT INTO usuario (nombre_usuario, contrasena_hash, rol)
VALUES ('bibliotecario.prueba',
        '$2a$10$abcdefghijklmnopqrstuuK0z3bQ5wHq9pYv8nZ1sX2cR4dE6fG7h',
        'bibliotecario');

-- p y d: días atrás del préstamo y de la devolución (NULL = abierto).
-- Plazo de 14 días. Los lectores se buscan por documento.
INSERT INTO prestamo (id_lector, isbn, registrado_por, devuelto_por,
                      fecha_prestamo, fecha_vencimiento, fecha_devolucion)
SELECT l.id_lector, v.isbn, b.id_usuario,
       CASE WHEN v.d IS NOT NULL THEN b.id_usuario END,
       CURRENT_DATE - v.p,
       CURRENT_DATE - v.p + 14,
       CURRENT_DATE - v.d
FROM (VALUES
    -- Mariana: 3 devueltos a tiempo
    ('1000000001', '9780000000001', 120, 110),
    ('1000000001', '9780000000004', 100,  90),
    ('1000000001', '9780000000007',  80,  70),
    -- Santiago: 3 devueltos; el Quijote, 6 días tarde (fue mora, ya no lo es)
    ('1000000002', '9780000000001',  95,  85),
    ('1000000002', '9780000000005',  75,  65),
    ('1000000002', '9780000000009',  60,  40),
    -- Valentina: 1 devuelto, 1 abierto en mora y 1 abierto todavía a tiempo
    ('1000000003', '9780000000001',  70,  60),
    ('1000000003', '9780000000010',  30, NULL),
    ('1000000003', '9780000000003',   5, NULL),
    -- Juan David: 0 devueltos y 3 abiertos (2 en mora; Rayuela vence hoy)
    ('1000000004', '9780000000001',  20, NULL),
    ('1000000004', '9780000000004',  14, NULL),
    ('1000000004', '9780000000007',  40, NULL),
    -- Camila: 2 devueltos y 1 abierto en mora
    ('1000000005', '9780000000004',  50,  45),
    ('1000000005', '9780000000011',  35,  30),
    ('1000000005', '9780000000005',  16, NULL)
    -- Sebastián y los demás lectores: ningún préstamo
) AS v (documento, isbn, p, d)
JOIN lector  l ON l.documento = v.documento
CROSS JOIN (SELECT id_usuario FROM usuario
            WHERE nombre_usuario = 'bibliotecario.prueba') b;

SELECT count(*) AS prestamos,
       count(*) FILTER (WHERE fecha_devolucion IS NULL) AS abiertos,
       count(*) FILTER (WHERE fecha_devolucion IS NULL
                          AND fecha_vencimiento < CURRENT_DATE) AS en_mora
FROM prestamo;

\echo
\echo '== Reporte 1. Los libros más prestados (los 3 primeros, con empates) =='
-- LEFT JOIN para que un libro sin préstamos cuente 0 y no desaparezca.
SELECT b.titulo, b.autor, count(p.id_prestamo) AS prestamos
FROM   libro b
LEFT JOIN prestamo p ON p.isbn = b.isbn
WHERE  b.activo
GROUP BY b.isbn, b.titulo, b.autor
ORDER BY prestamos DESC, b.titulo
FETCH FIRST 3 ROWS WITH TIES;

\echo '== Reporte 2. El o los lectores que más libros han leído (préstamos devueltos) =='
WITH leidos AS (
    SELECT id_lector, count(*) AS devueltos
    FROM   prestamo
    WHERE  fecha_devolucion IS NOT NULL
    GROUP BY id_lector
)
SELECT l.documento, l.nombres, l.apellidos, x.devueltos
FROM   leidos x
JOIN   lector l ON l.id_lector = x.id_lector
WHERE  x.devueltos = (SELECT max(devueltos) FROM leidos)
ORDER BY l.apellidos;

\echo '== Reporte 3. Lectores morosos (al menos un préstamo abierto y vencido) =='
-- Rayuela de Juan David vence hoy: todavía no está en mora (< y no <=).
SELECT l.documento, l.nombres, l.apellidos
FROM   lector l
WHERE  EXISTS (SELECT 1
               FROM   prestamo p
               WHERE  p.id_lector = l.id_lector
                 AND  p.fecha_devolucion IS NULL
                 AND  p.fecha_vencimiento < CURRENT_DATE)
ORDER BY l.apellidos;

\echo '== Reporte 4. Préstamos en mora (lista de notificación) =='
SELECT l.nombres || ' ' || l.apellidos          AS lector,
       l.correo, l.telefono,
       b.titulo,
       p.fecha_vencimiento,
       CURRENT_DATE - p.fecha_vencimiento        AS dias_mora
FROM   prestamo p
JOIN   lector l ON l.id_lector = p.id_lector
JOIN   libro  b ON b.isbn      = p.isbn
WHERE  p.fecha_devolucion IS NULL
  AND  p.fecha_vencimiento < CURRENT_DATE
ORDER BY dias_mora DESC, lector;

ROLLBACK;

\echo '== Después del ROLLBACK la base queda como estaba =='
SELECT count(*) AS prestamos FROM prestamo;
