-- ============================================================
-- consultas-reportes.sql  (PostgreSQL 16)
-- Proyecto Biblioteca - Grupo 1
--
-- Las 4 consultas de los reportes del Hito 2.
-- Antes devolvian cero filas porque prestamo estaba vacia.
-- Con carga-prestamos.sql ya cargado, devuelven datos.
--
-- Este archivo NO usa meta-comandos de psql (\set, \if...), asi que
-- se puede pegar tal cual en el Query Tool de pgAdmin.
--
-- Uso desde terminal:
--   docker compose exec -T postgres psql -U curso -d curso \
--     -f /scripts/consultas-reportes.sql
-- ============================================================

SET search_path TO biblioteca;

-- ---------------------------------------------------------------
-- Reporte 1: los 20 libros mas prestados
-- ---------------------------------------------------------------
SELECT
    l.isbn,
    l.titulo,
    l.autor,
    COUNT(p.id_prestamo) AS prestamos
FROM libro l
JOIN prestamo p ON p.isbn = l.isbn
GROUP BY l.isbn, l.titulo, l.autor
ORDER BY prestamos DESC, l.titulo ASC
LIMIT 20;

-- ---------------------------------------------------------------
-- Reporte 2: los usuarios que mas libros han leido
-- Cuentan prestamos COMPLETADOS (con fecha de devolucion), no los
-- abiertos, para no premiar a quien solo retiene libros.
-- ---------------------------------------------------------------
SELECT
    u.nombre_usuario,
    le.nombres,
    le.apellidos,
    COUNT(p.id_prestamo) AS leidos
FROM prestamo p
JOIN lector le ON le.id_lector = p.id_lector
JOIN usuario u ON u.id_usuario = le.id_usuario
WHERE p.fecha_devolucion IS NOT NULL
GROUP BY u.nombre_usuario, le.nombres, le.apellidos
ORDER BY leidos DESC, u.nombre_usuario ASC;

-- ---------------------------------------------------------------
-- Reporte 3: lista de usuarios morosos
-- Un prestamo esta en mora cuando la fecha esperada de devolucion
-- ya paso y el libro no ha sido devuelto.
-- ---------------------------------------------------------------
SELECT
    u.nombre_usuario,
    le.nombres,
    le.apellidos,
    le.correo,
    le.telefono,
    l.titulo,
    p.fecha_prestamo,
    p.fecha_vencimiento,
    (CURRENT_DATE - p.fecha_vencimiento) AS dias_de_atraso
FROM prestamo p
JOIN lector le ON le.id_lector = p.id_lector
JOIN usuario u ON u.id_usuario = le.id_usuario
JOIN libro l ON l.isbn = p.isbn
WHERE
    p.fecha_devolucion IS NULL
    AND p.fecha_vencimiento < CURRENT_DATE
ORDER BY p.fecha_vencimiento ASC;

-- ---------------------------------------------------------------
-- Reporte 4: notificacion de prestamos en mora
-- Es una LISTA para mostrar en la aplicacion (la GUI pone un boton
-- "Enviar notificacion" que no ejecuta ninguna accion real).
-- ---------------------------------------------------------------
SELECT
    le.nombres || ' ' || le.apellidos AS lector,
    le.correo,
    le.telefono,
    l.titulo AS libro,
    p.fecha_vencimiento,
    (CURRENT_DATE - p.fecha_vencimiento) AS dias_de_atraso
FROM prestamo p
JOIN lector le ON le.id_lector = p.id_lector
JOIN libro l ON l.isbn = p.isbn
WHERE
    p.fecha_devolucion IS NULL
    AND p.fecha_vencimiento < CURRENT_DATE
ORDER BY p.fecha_vencimiento ASC;
