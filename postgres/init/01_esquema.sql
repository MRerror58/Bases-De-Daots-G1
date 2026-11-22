-- Proyecto Biblioteca - Grupo 1
-- Esquema normalizado del Hito 3 (S20). Parte del de S14/S16 con los cambios
-- del análisis de S19: catálogos de autor, categoría y editorial; ejemplares
-- físicos; préstamo por ejemplar; disponibles calculados en una vista.
-- Una base que ya tenía el esquema anterior se migra con
-- postgres/scripts/normalizacion.sql, sin perder datos.

DROP SCHEMA IF EXISTS biblioteca CASCADE;
CREATE SCHEMA biblioteca;
SET search_path TO biblioteca;

CREATE TABLE usuario (
    id_usuario       integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nombre_usuario   varchar(120) NOT NULL UNIQUE,
    contrasena_hash  varchar(255) NOT NULL,
    rol              varchar(20) NOT NULL
                     CHECK (rol IN ('lector', 'bibliotecario', 'administrador', 'auditor')),
    activo            boolean NOT NULL DEFAULT true,
    fecha_creacion    timestamp NOT NULL DEFAULT now()
);

COMMENT ON COLUMN usuario.nombre_usuario IS
    'Login de la cuenta. La carga inicial usa el documento del lector, pero es un dato propio de la cuenta: cambiarlo no cambia el documento, ni al revés.';
COMMENT ON COLUMN usuario.activo IS
    'La cuenta puede iniciar sesión.';

CREATE TABLE lector (
    id_lector       integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_usuario      integer NOT NULL UNIQUE,

    documento       varchar(15) NOT NULL UNIQUE
                    CHECK (documento ~ '^[0-9]{6,15}$'),

    nombres         varchar(80) NOT NULL
                    CHECK (btrim(nombres) <> ''),

    apellidos       varchar(80) NOT NULL
                    CHECK (btrim(apellidos) <> ''),

    -- Único sin distinguir mayúsculas: ver el índice lector_correo_lower_key.
    correo          varchar(120) NOT NULL
                    CHECK (correo ~ '^[^@ ]+@[^@ ]+\.[^@ ]+$'),

    telefono        varchar(15)
                    CHECK (
                        telefono IS NULL
                        OR telefono ~ '^[0-9]{7,15}$'
                    ),

    direccion       varchar(200),
    fecha_registro  date NOT NULL DEFAULT CURRENT_DATE,
    activo          boolean NOT NULL DEFAULT true,

    CONSTRAINT fk_lector_usuario
        FOREIGN KEY (id_usuario)
        REFERENCES usuario(id_usuario)
);

CREATE UNIQUE INDEX lector_correo_lower_key ON lector (lower(correo));

COMMENT ON COLUMN lector.activo IS
    'El lector puede pedir préstamos. Es independiente de usuario.activo: un lector suspendido puede seguir entrando a consultar su historial.';

-- Catálogos: cada nombre se escribe una sola vez.

CREATE TABLE categoria (
    id_categoria  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nombre        varchar(40) NOT NULL UNIQUE
                  CHECK (btrim(nombre) <> '')
);

CREATE TABLE autor (
    id_autor  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nombre    varchar(120) NOT NULL UNIQUE
              CHECK (btrim(nombre) <> '')
);

CREATE TABLE editorial (
    id_editorial  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nombre        varchar(120) NOT NULL UNIQUE
                  CHECK (btrim(nombre) <> '')
);

CREATE TABLE libro (
    isbn                    varchar(13) PRIMARY KEY
                            CHECK (isbn ~ '^[0-9]{13}$'),

    titulo                  varchar(200) NOT NULL
                            CHECK (btrim(titulo) <> ''),

    id_categoria            integer NOT NULL,
    id_editorial            integer,            -- todavía ningún libro la tiene

    anio_publicacion        smallint NOT NULL
                            CHECK (anio_publicacion BETWEEN 1450 AND 2100),

    activo                  boolean NOT NULL DEFAULT true,

    CONSTRAINT fk_libro_categoria
        FOREIGN KEY (id_categoria)
        REFERENCES categoria(id_categoria),

    CONSTRAINT fk_libro_editorial
        FOREIGN KEY (id_editorial)
        REFERENCES editorial(id_editorial)
);

-- Un libro puede tener varios autores, y un autor varios libros.
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

-- Cada copia física de un libro. Reemplaza a libro.ejemplares_disponibles:
-- el total se cuenta y los disponibles se calculan (vista libro_disponibilidad).
CREATE TABLE ejemplar (
    id_ejemplar  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    isbn         varchar(13) NOT NULL,
    activo       boolean NOT NULL DEFAULT true,   -- false = dado de baja

    CONSTRAINT fk_ejemplar_libro
        FOREIGN KEY (isbn)
        REFERENCES libro(isbn)
);

CREATE TABLE prestamo (
    id_prestamo       integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,

    id_lector         integer NOT NULL,
    id_ejemplar       integer NOT NULL,

    -- Usuario con rol bibliotecario que registra el préstamo (la validación
    -- del rol necesita mirar otra tabla: trigger del Hito 4)
    registrado_por    integer NOT NULL,

    -- NULL mientras el libro no haya sido devuelto
    devuelto_por      integer,

    fecha_prestamo    date NOT NULL,
    -- Dato histórico: el plazo vigente el día del préstamo. No se calcula.
    fecha_vencimiento date NOT NULL,
    fecha_devolucion  date,

    CONSTRAINT fk_prestamo_lector
        FOREIGN KEY (id_lector)
        REFERENCES lector(id_lector),

    CONSTRAINT fk_prestamo_ejemplar
        FOREIGN KEY (id_ejemplar)
        REFERENCES ejemplar(id_ejemplar),

    CONSTRAINT fk_prestamo_registrado_por
        FOREIGN KEY (registrado_por)
        REFERENCES usuario(id_usuario),

    CONSTRAINT fk_prestamo_devuelto_por
        FOREIGN KEY (devuelto_por)
        REFERENCES usuario(id_usuario),

    -- Clave natural: el mismo lector no saca el mismo ejemplar dos veces el mismo día.
    CONSTRAINT uq_prestamo_natural
        UNIQUE (id_lector, id_ejemplar, fecha_prestamo),

    CONSTRAINT chk_fecha_vencimiento
        CHECK (fecha_vencimiento >= fecha_prestamo),

    CONSTRAINT chk_fecha_devolucion
        CHECK (
            fecha_devolucion IS NULL
            OR fecha_devolucion >= fecha_prestamo
        ),

    -- Quién recibió el libro y cuándo se devolvió van juntos o no van.
    CONSTRAINT chk_devolucion_completa
        CHECK ((devuelto_por IS NULL) = (fecha_devolucion IS NULL))
);

-- Un ejemplar no puede estar prestado dos veces a la vez. Es además el
-- índice que usa la vista de disponibles (parcial: solo préstamos abiertos).
CREATE UNIQUE INDEX prestamo_abierto_key ON prestamo (id_ejemplar)
    WHERE fecha_devolucion IS NULL;

-- Índices para los joins por FK de las consultas frecuentes: el catálogo
-- (ejemplares de un libro), la búsqueda por autor y los préstamos de un
-- lector (historial, morosos). PostgreSQL no los crea solo para una FK.
CREATE INDEX ejemplar_isbn_idx      ON ejemplar (isbn);
CREATE INDEX libro_autor_autor_idx  ON libro_autor (id_autor);
CREATE INDEX prestamo_lector_idx    ON prestamo (id_lector);

-- Vistas: lo derivado se calcula, no se guarda.

-- Disponibles = ejemplares activos menos los que tienen un préstamo abierto.
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

-- El libro con sus autores y su categoría en una fila, como lo leen los reportes.
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

-- El estado del préstamo se deduce de las fechas; guardarlo sería otra copia.
CREATE VIEW prestamo_estado AS
SELECT p.id_prestamo, p.id_lector, p.id_ejemplar, p.registrado_por, p.devuelto_por,
       p.fecha_prestamo, p.fecha_vencimiento, p.fecha_devolucion,
       CASE
           WHEN p.fecha_devolucion IS NOT NULL        THEN 'devuelto'
           WHEN p.fecha_vencimiento < CURRENT_DATE    THEN 'vencido'
           ELSE 'activo'
       END AS estado
FROM   prestamo p;

-- Tablas auxiliares de la carga desde CSV (S14); no son parte del modelo conceptual.

CREATE TABLE rechazo_carga (
    id         integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    archivo    text NOT NULL,
    linea      integer NOT NULL,
    contenido  text NOT NULL,
    motivo     text NOT NULL,
    fecha      timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE stg_linea (
    n      integer GENERATED ALWAYS AS IDENTITY,
    linea  text
);

-- Todo se recibe como texto para poder validar antes de convertir. Las
-- columnas siguen el encabezado del CSV: "ejemplares_disponibles" del archivo
-- es el número de copias que llegan, y la carga crea una fila de ejemplar por cada una.
CREATE TABLE stg_libro (
    linea_csv               integer,
    contenido               text,
    num_campos              integer,
    isbn                    text,
    titulo                  text,
    autor                   text,
    categoria               text,
    anio_publicacion        text,
    ejemplares_disponibles  text,
    motivo                  text
);

CREATE TABLE stg_lector (
    linea_csv   integer,
    contenido   text,
    num_campos  integer,
    documento   text,
    nombres     text,
    apellidos   text,
    correo      text,
    telefono    text,
    motivo      text
);
