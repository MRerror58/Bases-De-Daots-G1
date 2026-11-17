-- S11. Solución de referencia (solo profesor): caso "matrículas de una universidad"
-- (diagrama E-R de referencia en ../modulo-2-entidad-relacion/S6-solucion-referencia.md)
--
-- Uso (desde entorno-docker/, con este archivo copiado en postgres/scripts/):
--   docker compose exec postgres psql -U curso -d curso -f /scripts/S11-matriculas-referencia.sql
--
-- Re-ejecutable: borra y recrea el esquema "matriculas".

DROP SCHEMA IF EXISTS matriculas CASCADE;
CREATE SCHEMA matriculas;
SET search_path TO matriculas;

-- Entidades fuertes ---------------------------------------------------------

CREATE TABLE programa (
    codigo  varchar(6)   PRIMARY KEY,
    nombre  varchar(80)  NOT NULL UNIQUE
);

-- Relación 1 "inscribe" (1:N, Estudiante total): FK en el lado N, NOT NULL.
CREATE TABLE estudiante (
    codigo           varchar(10)  PRIMARY KEY,
    nombre           varchar(80)  NOT NULL,
    correo           varchar(80)  NOT NULL UNIQUE,
    codigo_programa  varchar(6)   NOT NULL REFERENCES programa (codigo)
);

CREATE TABLE curso (
    codigo    varchar(8)   PRIMARY KEY,
    nombre    varchar(80)  NOT NULL,
    creditos  smallint     NOT NULL CHECK (creditos BETWEEN 1 AND 10)
);

CREATE TABLE profesor (
    cedula  varchar(12)  PRIMARY KEY,
    nombre  varchar(80)  NOT NULL,
    correo  varchar(80)  NOT NULL UNIQUE
);

CREATE TABLE edificio (
    codigo  varchar(6)   PRIMARY KEY,
    nombre  varchar(80)  NOT NULL
);

-- Entidades débiles ---------------------------------------------------------

-- Relación 7 "contiene" (identificadora): PK = PK de la fuerte + clave parcial.
CREATE TABLE aula (
    codigo_edificio  varchar(6)   REFERENCES edificio (codigo) ON DELETE CASCADE,
    numero           varchar(6),
    capacidad        smallint     NOT NULL CHECK (capacidad > 0),
    tipo             varchar(20)  NOT NULL
                     CHECK (tipo IN ('salon', 'sala de computo', 'laboratorio')),
    PRIMARY KEY (codigo_edificio, numero)
);

-- Relación 3 "se abre en" (identificadora) + relación 4 "dicta" (1:N, Grupo total).
CREATE TABLE grupo (
    codigo_curso     varchar(8)   REFERENCES curso (codigo) ON DELETE CASCADE,
    periodo          varchar(6)   CHECK (periodo ~ '^[0-9]{4}-[12]$'),
    numero           varchar(3),
    cupo             smallint     NOT NULL CHECK (cupo > 0),
    cedula_profesor  varchar(12)  NOT NULL REFERENCES profesor (cedula),
    PRIMARY KEY (codigo_curso, periodo, numero)
);

-- Relaciones N:M → tabla propia ---------------------------------------------

-- Relación 2 "incluye" (plan de estudios).
-- La participación total de Curso ("todo curso está en al menos un programa")
-- NO se puede expresar con PK/FK/NOT NULL: queda documentada (trigger en M6).
CREATE TABLE plan_estudios (
    codigo_programa  varchar(6)  REFERENCES programa (codigo),
    codigo_curso     varchar(8)  REFERENCES curso (codigo),
    PRIMARY KEY (codigo_programa, codigo_curso)
);

-- Relación 5 "se matricula en", con su atributo nota_final.
-- La FK hacia grupo es compuesta: se referencia la PK completa de la débil.
CREATE TABLE matricula (
    codigo_estudiante  varchar(10),
    codigo_curso       varchar(8),
    periodo            varchar(6),
    numero_grupo       varchar(3),
    nota_final         numeric(2,1) CHECK (nota_final BETWEEN 0.0 AND 5.0),  -- NULL mientras el semestre está en curso
    PRIMARY KEY (codigo_estudiante, codigo_curso, periodo, numero_grupo),
    FOREIGN KEY (codigo_estudiante) REFERENCES estudiante (codigo),
    FOREIGN KEY (codigo_curso, periodo, numero_grupo)
        REFERENCES grupo (codigo_curso, periodo, numero)
);

-- Relación 6 "se programa en", con dia/hora_inicio/hora_fin.
-- dia y hora_inicio entran a la PK: así un grupo puede estar en la misma aula
-- lunes y miércoles (la "nota fina" de S6: equivale a la entidad débil Franja).
-- La participación total de Grupo ("toda franja…") tampoco es expresable con FK.
CREATE TABLE horario (
    codigo_curso     varchar(8),
    periodo          varchar(6),
    numero_grupo     varchar(3),
    dia              varchar(9)  CHECK (dia IN ('lunes', 'martes', 'miercoles', 'jueves', 'viernes', 'sabado')),
    hora_inicio      time,
    hora_fin         time        NOT NULL,
    codigo_edificio  varchar(6)  NOT NULL,
    numero_aula      varchar(6)  NOT NULL,
    PRIMARY KEY (codigo_curso, periodo, numero_grupo, dia, hora_inicio),
    FOREIGN KEY (codigo_curso, periodo, numero_grupo)
        REFERENCES grupo (codigo_curso, periodo, numero) ON DELETE CASCADE,
    FOREIGN KEY (codigo_edificio, numero_aula)
        REFERENCES aula (codigo_edificio, numero),
    CHECK (hora_fin > hora_inicio)
);

-- Datos mínimos para comprobar que el esquema acepta el caso del enunciado --

INSERT INTO programa VALUES ('3743', 'Ingeniería de Sistemas'), ('3752', 'Estadística');
INSERT INTO curso VALUES ('750006C', 'Bases de Datos', 4), ('750001C', 'Programación I', 3);
INSERT INTO plan_estudios VALUES ('3743', '750006C'), ('3743', '750001C'), ('3752', '750006C');
INSERT INTO estudiante VALUES ('2610001', 'Ana Torres', 'ana.torres@correounivalle.edu.co', '3743');
INSERT INTO profesor VALUES ('31000111', 'Rosa Díaz', 'rosa.diaz@correounivalle.edu.co'),
                            ('94000222', 'Luis Mora', 'luis.mora@correounivalle.edu.co');
INSERT INTO edificio VALUES ('331', 'Ingeniería de Sistemas'), ('344', 'Aulas de Ingeniería');
INSERT INTO aula VALUES ('331', '101', 30, 'sala de computo'), ('344', '101', 40, 'salon');
INSERT INTO grupo VALUES ('750006C', '2026-2', '01', 40, '31000111'),
                         ('750006C', '2027-1', '01', 40, '94000222');
INSERT INTO horario VALUES
    ('750006C', '2026-2', '01', 'lunes',     '07:00', '09:00', '331', '101'),
    ('750006C', '2026-2', '01', 'miercoles', '07:00', '09:00', '331', '101');  -- misma aula, otro día
-- Ana pierde en 2026-2 y repite en 2027-1: dos filas, sin conflicto de PK.
INSERT INTO matricula VALUES ('2610001', '750006C', '2026-2', '01', 2.4),
                             ('2610001', '750006C', '2027-1', '01', NULL);
