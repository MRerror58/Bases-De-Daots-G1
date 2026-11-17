-- S17. Redundancia, anomalías de actualización y dependencia funcional
-- Caso: la "planilla" de préstamos de una biblioteca que todo lo guarda en
-- una sola tabla, y la versión plana de las matrículas de S9, S13 y S15
--
-- Uso (desde entorno-docker/, con este archivo copiado en postgres/scripts/):
--   docker compose exec postgres psql -U curso -d curso -f /scripts/S17-planilla.sql
--
-- Se puede correr cuantas veces se quiera: borra y recrea el esquema
-- "planilla" completo, sin tocar nada más de la base. Las anomalías de la
-- guía (secciones 4 y 7) se prueban a mano sobre estas tablas; para volver
-- al estado inicial basta con correr de nuevo el script.
-- Para trabajar después sobre estas tablas desde psql o pgAdmin:
--   SET search_path TO planilla;

DROP SCHEMA IF EXISTS planilla CASCADE;
CREATE SCHEMA planilla;
SET search_path TO planilla;

-- ---------------------------------------------------------------
-- prestamo_plano: una fila por préstamo, con los datos del libro y
-- del lector copiados en cada una (como en una hoja de cálculo)
-- ---------------------------------------------------------------

CREATE TABLE prestamo_plano (
    id_prestamo       integer       PRIMARY KEY,
    isbn              varchar(13)   NOT NULL,
    titulo            varchar(200)  NOT NULL,
    autor             varchar(120)  NOT NULL,
    categoria         varchar(40)   NOT NULL,
    documento         varchar(15)   NOT NULL,
    nombres           varchar(80)   NOT NULL,
    apellidos         varchar(80)   NOT NULL,
    correo            varchar(120)  NOT NULL,
    telefono          varchar(15),
    fecha_prestamo    date          NOT NULL,
    fecha_esperada    date          NOT NULL,
    fecha_devolucion  date                      -- NULL = préstamo abierto
);

INSERT INTO prestamo_plano VALUES
    (1, '9780000000001', 'Cien años de soledad', 'Gabriel García Márquez', 'Novela',
        '1000000001', 'Mariana', 'Gómez Rojas', 'mariana.gomez@correo-ejemplo.edu.co', '3001000001',
        '2026-09-01', '2026-09-15', '2026-09-10'),
    (2, '9780000000004', 'Rayuela', 'Julio Cortázar', 'Novela',
        '1000000001', 'Mariana', 'Gómez Rojas', 'mariana.gomez@correo-ejemplo.edu.co', '3001000001',
        '2026-09-12', '2026-09-26', '2026-09-20'),
    (3, '9780000000001', 'Cien años de soledad', 'Gabriel García Márquez', 'Novela',
        '1000000004', 'Juan David', 'Martínez Ruiz', 'juan.martinez@correo-ejemplo.edu.co', '3001000004',
        '2026-09-12', '2026-09-26', NULL),
    (4, '9780000000007', 'Ficciones', 'Jorge Luis Borges', 'Cuento',
        '1000000004', 'Juan David', 'Martínez Ruiz', 'juan.martinez@correo-ejemplo.edu.co', '3001000004',
        '2026-09-20', '2026-10-04', NULL),
    (5, '9780000000008', 'El Aleph', 'Jorge Luis Borges', 'Cuento',
        '1000000005', 'Camila', 'Hernández Torres', 'camila.hernandez@correo-ejemplo.edu.co', '3001000005',
        '2026-09-20', '2026-10-04', '2026-10-01'),
    (6, '9780000000001', 'Cien años de soledad', 'Gabriel García Márquez', 'Novela',
        '1000000002', 'Santiago', 'Rodríguez Pérez', 'santiago.rodriguez@correo-ejemplo.edu.co', '3001000002',
        '2026-10-01', '2026-10-15', '2026-10-14'),
    (7, '9780000000004', 'Rayuela', 'Julio Cortázar', 'Novela',
        '1000000003', 'Valentina', 'López Díaz', 'valentina.lopez@correo-ejemplo.edu.co', '3001000003',
        '2026-10-05', '2026-10-19', NULL),
    (8, '9780000000005', 'Pedro Páramo', 'Juan Rulfo', 'Novela',
        '1000000004', 'Juan David', 'Martínez Ruiz', 'juan.martinez@correo-ejemplo.edu.co', '3001000004',
        '2026-10-05', '2026-10-19', NULL);

-- ---------------------------------------------------------------
-- aprobo_plano: las matrículas de S15 (sin Elena ni Seminario, que no
-- tienen filas en aprobo) en una sola tabla. Se retoma en S18.
-- ---------------------------------------------------------------

CREATE TABLE aprobo_plano (
    cod_est       integer       NOT NULL,
    nombre        varchar(80)   NOT NULL,
    cod_prog      integer       NOT NULL,
    nombre_prog   varchar(80)   NOT NULL,
    cod_curso     varchar(10)   NOT NULL,
    nombre_curso  varchar(80)   NOT NULL,
    creditos      smallint      NOT NULL,
    nota          numeric(2,1)  NOT NULL,
    PRIMARY KEY (cod_est, cod_curso)
);

INSERT INTO aprobo_plano VALUES
    (2610001, 'Ana',   3743, 'Ingeniería de Sistemas', '750006C', 'Bases de Datos', 4, 4.5),
    (2610001, 'Ana',   3743, 'Ingeniería de Sistemas', '750001C', 'Programación I', 3, 3.8),
    (2610001, 'Ana',   3743, 'Ingeniería de Sistemas', '760001C', 'Estadística I',  3, 3.2),
    (2610002, 'Bruno', 3743, 'Ingeniería de Sistemas', '750001C', 'Programación I', 3, 4.0),
    (2610003, 'Carla', 3752, 'Estadística',            '760001C', 'Estadística I',  3, 4.7),
    (2610004, 'Diego', 3743, 'Ingeniería de Sistemas', '750006C', 'Bases de Datos', 4, 3.0),
    (2610004, 'Diego', 3743, 'Ingeniería de Sistemas', '750001C', 'Programación I', 3, 3.5);

-- ---------------------------------------------------------------
-- Verificación: 8 préstamos y 7 notas
-- ---------------------------------------------------------------

SELECT 'prestamo_plano' AS tabla, count(*) AS filas FROM prestamo_plano
UNION ALL
SELECT 'aprobo_plano', count(*) FROM aprobo_plano;
