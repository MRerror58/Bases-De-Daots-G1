-- =====================================================================
-- S19. Taller: detectar y corregir esquemas mal diseñados
-- Grupo 1 - Proyecto Biblioteca
-- Integrantes:
--   Santiago Ruiz Vanegas         (202177804)
--   Juan David Vasquez Cañas      (2515123)
--   Omar Esteban Agredo Titimbo   (2516317)
--
-- Uso (desde entorno-docker/, con este archivo en postgres/scripts/):
--   docker compose exec postgres psql -U curso -d curso -f /scripts/S19-esquemas.sql
--   docker compose exec postgres psql -U curso -d curso -e -f /scripts/casos.sql
--
-- Primero hay que correr S19-esquemas.sql, porque las migraciones cambian
-- los cuatro esquemas. Si una verificación falla, el ASSERT aborta la
-- transacción y ON_ERROR_STOP detiene el script: la base queda como estaba.
-- =====================================================================

\set ON_ERROR_STOP on


-- #####################################################################
-- CASO 1: GIMNASIO
-- socio (id_socio PK, nombre, plan, valor_plan, clases)
-- #####################################################################
\echo
\echo '=================== CASO 1: GIMNASIO ==================='
SET search_path TO gimnasio;

-- (a) DIAGNÓSTICO
--
-- Dependencias funcionales:
--   id_socio -> nombre, plan, valor_plan, clases
--   plan     -> valor_plan          (regla: cada plan tiene un valor fijo)
--
-- Problema principal (explica la queja): NO ESTÁ EN 1FN.
--   "clases" guarda una lista separada por ';'. El atributo no es atómico,
--   y para buscar una clase hay que usar LIKE sobre el texto:
--   * 'Spinning' coincide también con 'Spinning avanzado' (socio 2), así
--     que el sistema cuenta 3 en Spinning cuando son 2;
--   * el socio 3 escribió 'yoga' en minúscula y LIKE '%Yoga%' no lo
--     encuentra: el sistema cuenta 2 en Yoga cuando son 3.
--   Además, los pedazos tienen espacios sobrantes ('Yoga ', ' Spinning')
--   y no hay un catálogo de clases que impida escribir mal un nombre.
--
-- Problema secundario: NO ESTÁ EN 3FN.
--   plan -> valor_plan, y plan no es clave: es una dependencia transitiva
--   (id_socio -> plan -> valor_plan). El valor del plan se repite en cada
--   socio, y para cambiarlo habría que actualizar muchas filas sin dejar
--   ninguna atrás.

-- (b) EVIDENCIA

-- La queja, tal como la ve el sistema: Yoga = 2 y Spinning = 3
SELECT count(*) AS yoga_segun_sistema     FROM socio WHERE clases LIKE '%Yoga%';
SELECT count(*) AS spinning_segun_sistema FROM socio WHERE clases LIKE '%Spinning%';

-- Por qué falla: el socio 3 tiene 'yoga' en minúscula, el 2 tiene 'Spinning avanzado'
SELECT id_socio, nombre, clases,
       clases LIKE '%Yoga%'     AS like_yoga,
       clases LIKE '%Spinning%' AS like_spinning
FROM socio
ORDER BY id_socio;

-- Los pedazos crudos, entre comillas para ver los espacios sobrantes
SELECT s.id_socio, '"' || c || '"' AS pedazo_crudo
FROM socio s, string_to_table(s.clases, ';') AS c
ORDER BY s.id_socio;

-- plan -> valor_plan: los datos no la contradicen (ningún plan tiene 2 valores)...
SELECT plan FROM socio GROUP BY plan HAVING count(DISTINCT valor_plan) > 1;
-- ...y el mismo valor se repite en cada socio del plan (redundancia)
SELECT plan, valor_plan, count(*) AS veces_repetido
FROM socio GROUP BY plan, valor_plan ORDER BY count(*) DESC;

-- (c) ESQUEMA CORREGIDO
--   plan        (nombre PK, valor)
--   socio       (id_socio PK, nombre, plan FK -> plan)
--   clase       (id_clase PK, nombre UNIQUE)
--   socio_clase (id_socio FK -> socio, id_clase FK -> clase,
--                PK (id_socio, id_clase))
--
-- Conteos esperados, calculados a mano ANTES de migrar:
--   plan: 3 (Mensual, Trimestral, Anual)
--   clase: 5 (Yoga, Spinning, Spinning avanzado, Pilates, Funcional)
--   socio: 6 (Sofía, sin clases, también se queda)
--   socio_clase: 2 + 1 + 2 + 3 + 0 + 1 = 9
--
-- Limpieza de los nombres: btrim quita espacios, y se deja la primera letra
-- en mayúscula y el resto en minúscula. No se usa initcap porque convertiría
-- 'Spinning avanzado' en 'Spinning Avanzado'.

-- (d) MIGRACIÓN
BEGIN;

CREATE TEMP TABLE pieza ON COMMIT DROP AS
SELECT s.id_socio,
       upper(left(btrim(c), 1)) || lower(substr(btrim(c), 2)) AS clase
FROM socio s, string_to_table(s.clases, ';') AS c
WHERE btrim(c) <> '';

CREATE TABLE plan (
    nombre  varchar(20)  PRIMARY KEY,
    valor   integer      NOT NULL CHECK (valor > 0)
);
INSERT INTO plan (nombre, valor)
SELECT DISTINCT plan, valor_plan FROM socio;

CREATE TABLE clase (
    id_clase  integer      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nombre    varchar(40)  NOT NULL UNIQUE
);
INSERT INTO clase (nombre)
SELECT DISTINCT clase FROM pieza ORDER BY clase;

CREATE TABLE socio_clase (
    id_socio  integer  NOT NULL REFERENCES socio (id_socio),
    id_clase  integer  NOT NULL REFERENCES clase (id_clase),
    PRIMARY KEY (id_socio, id_clase)
);
INSERT INTO socio_clase (id_socio, id_clase)
SELECT DISTINCT p.id_socio, c.id_clase
FROM pieza p JOIN clase c ON c.nombre = p.clase;

-- (e) VERIFICACIÓN, antes de borrar lo viejo
SELECT 'plan' AS tabla, 3 AS esperado, count(*) AS obtenido FROM plan
UNION ALL SELECT 'clase',       5, count(*) FROM clase
UNION ALL SELECT 'socio',       6, count(*) FROM socio
UNION ALL SELECT 'socio_clase', 9, count(*) FROM socio_clase;

DO $$
BEGIN
    ASSERT (SELECT count(*) FROM plan) = 3,        'plan: se esperaban 3';
    ASSERT (SELECT count(*) FROM clase) = 5,       'clase: se esperaban 5';
    ASSERT (SELECT count(*) FROM socio) = 6,       'socio: se esperaban 6';
    ASSERT (SELECT count(*) FROM socio_clase) = 9, 'socio_clase: se esperaban 9';
END $$;

-- Nada se pierde ni se inventa: lo viejo EXCEPT lo nuevo, y al revés (0 filas)
SELECT id_socio, clase FROM pieza
EXCEPT
SELECT sc.id_socio, c.nombre FROM socio_clase sc JOIN clase c USING (id_clase);

SELECT sc.id_socio, c.nombre FROM socio_clase sc JOIN clase c USING (id_clase)
EXCEPT
SELECT id_socio, clase FROM pieza;

SELECT s.id_socio, s.valor_plan FROM socio s
EXCEPT
SELECT s.id_socio, p.valor FROM socio s JOIN plan p ON p.nombre = s.plan;

-- Ya verificado: se quita lo viejo
ALTER TABLE socio
    ADD CONSTRAINT fk_socio_plan FOREIGN KEY (plan) REFERENCES plan (nombre),
    DROP COLUMN valor_plan,
    DROP COLUMN clases;

COMMIT;

-- La queja resuelta: Yoga = 3, Spinning = 2
SELECT c.nombre AS clase, count(sc.id_socio) AS socios
FROM clase c LEFT JOIN socio_clase sc USING (id_clase)
GROUP BY c.nombre
ORDER BY c.nombre;

-- PREGUNTA PROPIA: ¿dónde va el horario de cada clase (día y hora)?
--   El horario es un dato de la CLASE, no del socio ni de la inscripción:
--   id_clase -> horario. Si cada clase tiene un solo horario, se agregan
--   las columnas dia y hora a la tabla clase. Si una clase se dicta varias
--   veces por semana (lunes y miércoles, por ejemplo), va en una tabla
--   aparte: clase_horario (id_clase FK, dia, hora_inicio,
--   PK (id_clase, dia, hora_inicio)).
--
--   Con el diseño original no había dónde ponerlo bien. La clase no existía
--   como entidad: era un pedazo de texto dentro de cada socio. El horario
--   tendría que ir pegado al texto ('Yoga lun 7am; Spinning…') y repetido
--   en cada socio inscrito, sin forma de garantizar que todos los socios de
--   Yoga tuvieran el mismo horario (la misma redundancia que plan ->
--   valor_plan). Una clase sin socios inscritos ni siquiera tendría dónde
--   guardar su horario.


-- #####################################################################
-- CASO 2: FARMACIA
-- formula (num_formula PK, fecha, doc_paciente, nombre_paciente,
--          medicamento1, dosis1, medicamento2, dosis2, medicamento3, dosis3)
-- #####################################################################
\echo
\echo '=================== CASO 2: FARMACIA ==================='
SET search_path TO farmacia;

-- (a) DIAGNÓSTICO
--
-- Dependencias funcionales:
--   num_formula                 -> fecha, doc_paciente
--   doc_paciente                -> nombre_paciente
--   (num_formula, medicamento)  -> dosis
--   OJO: medicamento -> dosis NO se cumple. El acetaminofén va 'cada 8 h'
--   en una fórmula y 'cada 6 h' en otra, así que la dosis depende de la
--   fórmula y del medicamento juntos.
--
-- Problema principal (explica la queja): GRUPO REPETIDO, NO ESTÁ EN 1FN.
--   medicamento1..3 / dosis1..3 son el mismo atributo copiado tres veces.
--   Por eso nunca caben más de 3 medicamentos, y para buscar uno hay que
--   preguntar en las tres columnas. Las columnas 2 y 3 quedan en NULL casi
--   siempre.
--
-- Problemas secundarios:
--   * NO ESTÁ EN 3FN: num_formula -> doc_paciente -> nombre_paciente es una
--     dependencia transitiva. El nombre de Rosa Díaz se repite en cada
--     fórmula suya, y podría quedar escrito distinto en cada una.
--   * La regla "un medicamento no aparece dos veces en la misma fórmula"
--     no se puede declarar con UNIQUE: el mismo medicamento puede ir en
--     medicamento1 y medicamento2. Tampoco se impide que haya un
--     medicamento2 sin dosis2.
--   * No hay catálogo de medicamentos: el nombre es texto libre y se repite
--     en cada fórmula.

-- (b) EVIDENCIA

-- La queja: para contar fórmulas con acetaminofén hay que buscar en 3 columnas
SELECT count(*) AS formulas_con_acetaminofen
FROM formula
WHERE medicamento1 LIKE 'Acetaminof%'
   OR medicamento2 LIKE 'Acetaminof%'
   OR medicamento3 LIKE 'Acetaminof%';

-- En qué columna quedó en cada fórmula: cambia de una a otra
SELECT num_formula,
       CASE WHEN medicamento1 LIKE 'Acetaminof%' THEN 'medicamento1'
            WHEN medicamento2 LIKE 'Acetaminof%' THEN 'medicamento2'
            WHEN medicamento3 LIKE 'Acetaminof%' THEN 'medicamento3' END AS columna
FROM formula
WHERE 'Acetaminofén 500 mg' IN (medicamento1, medicamento2, medicamento3);

-- Huecos: casillas de medicamento vacías (de 12 posibles)
SELECT count(*) FILTER (WHERE medicamento2 IS NULL)
     + count(*) FILTER (WHERE medicamento3 IS NULL) AS casillas_vacias,
       count(*) * 3 AS casillas_totales
FROM formula;

-- doc_paciente -> nombre_paciente: no hay contradicciones, pero sí repeticiones
SELECT doc_paciente, nombre_paciente, count(*) AS veces
FROM formula GROUP BY doc_paciente, nombre_paciente ORDER BY count(*) DESC;
SELECT doc_paciente FROM formula GROUP BY doc_paciente
HAVING count(DISTINCT nombre_paciente) > 1;

-- medicamento -> dosis NO se cumple (por eso la dosis va con la fórmula)
WITH linea AS (
    SELECT num_formula, medicamento1 AS medicamento, dosis1 AS dosis FROM formula
    UNION ALL
    SELECT num_formula, medicamento2, dosis2 FROM formula WHERE medicamento2 IS NOT NULL
    UNION ALL
    SELECT num_formula, medicamento3, dosis3 FROM formula WHERE medicamento3 IS NOT NULL
)
SELECT medicamento, count(DISTINCT dosis) AS dosis_distintas,
       string_agg(DISTINCT dosis, ' / ') AS dosis
FROM linea GROUP BY medicamento HAVING count(DISTINCT dosis) > 1;

-- El diseño acepta el mismo medicamento dos veces y un medicamento sin dosis
BEGIN;
INSERT INTO formula VALUES
    (799, '2026-10-20', '1110000333', 'Elsa Mina',
     'Loratadina 10 mg', 'cada 24 h', 'Loratadina 10 mg', 'cada 12 h', 'Omeprazol 20 mg', NULL);
SELECT num_formula, medicamento1, medicamento2, medicamento3, dosis3
FROM formula WHERE num_formula = 799;   -- se aceptó
ROLLBACK;

-- (c) ESQUEMA CORREGIDO
--   paciente            (doc_paciente PK, nombre)
--   formula             (num_formula PK, fecha, doc_paciente FK -> paciente)
--   medicamento         (id_medicamento PK, nombre UNIQUE)
--   formula_medicamento (num_formula FK -> formula,
--                        id_medicamento FK -> medicamento,
--                        dosis NOT NULL,
--                        PK (num_formula, id_medicamento))
--   La PK de formula_medicamento es la regla "un medicamento no aparece dos
--   veces en la misma fórmula".
--
-- Conteos esperados, calculados a mano ANTES de migrar:
--   paciente: 3 (Rosa, Óscar, Elsa)
--   medicamento: 5 (Acetaminofén, Loratadina, Amoxicilina, Ibuprofeno, Omeprazol)
--   formula: 4
--   formula_medicamento: 2 + 1 + 3 + 2 = 8

-- (d) MIGRACIÓN
BEGIN;

CREATE TEMP TABLE linea ON COMMIT DROP AS
SELECT num_formula, medicamento1 AS medicamento, dosis1 AS dosis FROM formula
UNION ALL
SELECT num_formula, medicamento2, dosis2 FROM formula WHERE medicamento2 IS NOT NULL
UNION ALL
SELECT num_formula, medicamento3, dosis3 FROM formula WHERE medicamento3 IS NOT NULL;

CREATE TABLE paciente (
    doc_paciente  varchar(15)  PRIMARY KEY,
    nombre        varchar(80)  NOT NULL
);
INSERT INTO paciente (doc_paciente, nombre)
SELECT DISTINCT doc_paciente, nombre_paciente FROM formula;

CREATE TABLE medicamento (
    id_medicamento  integer      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nombre          varchar(60)  NOT NULL UNIQUE
);
INSERT INTO medicamento (nombre)
SELECT DISTINCT medicamento FROM linea ORDER BY medicamento;

CREATE TABLE formula_medicamento (
    num_formula     integer      NOT NULL REFERENCES formula (num_formula),
    id_medicamento  integer      NOT NULL REFERENCES medicamento (id_medicamento),
    dosis           varchar(40)  NOT NULL,
    PRIMARY KEY (num_formula, id_medicamento)
);
INSERT INTO formula_medicamento (num_formula, id_medicamento, dosis)
SELECT l.num_formula, m.id_medicamento, l.dosis
FROM linea l JOIN medicamento m ON m.nombre = l.medicamento;

-- (e) VERIFICACIÓN, antes de borrar lo viejo
SELECT 'paciente' AS tabla, 3 AS esperado, count(*) AS obtenido FROM paciente
UNION ALL SELECT 'medicamento',         5, count(*) FROM medicamento
UNION ALL SELECT 'formula',             4, count(*) FROM formula
UNION ALL SELECT 'formula_medicamento', 8, count(*) FROM formula_medicamento;

DO $$
BEGIN
    ASSERT (SELECT count(*) FROM paciente) = 3,            'paciente: se esperaban 3';
    ASSERT (SELECT count(*) FROM medicamento) = 5,         'medicamento: se esperaban 5';
    ASSERT (SELECT count(*) FROM formula) = 4,             'formula: se esperaban 4';
    ASSERT (SELECT count(*) FROM formula_medicamento) = 8, 'formula_medicamento: se esperaban 8';
END $$;

-- Lo viejo EXCEPT lo nuevo, y al revés (0 filas cada una)
SELECT num_formula, medicamento, dosis FROM linea
EXCEPT
SELECT fm.num_formula, m.nombre, fm.dosis
FROM formula_medicamento fm JOIN medicamento m USING (id_medicamento);

SELECT fm.num_formula, m.nombre, fm.dosis
FROM formula_medicamento fm JOIN medicamento m USING (id_medicamento)
EXCEPT
SELECT num_formula, medicamento, dosis FROM linea;

SELECT num_formula, doc_paciente, nombre_paciente FROM formula
EXCEPT
SELECT f.num_formula, p.doc_paciente, p.nombre
FROM formula f JOIN paciente p USING (doc_paciente);

ALTER TABLE formula
    ADD CONSTRAINT fk_formula_paciente
        FOREIGN KEY (doc_paciente) REFERENCES paciente (doc_paciente),
    DROP COLUMN nombre_paciente,
    DROP COLUMN medicamento1, DROP COLUMN dosis1,
    DROP COLUMN medicamento2, DROP COLUMN dosis2,
    DROP COLUMN medicamento3, DROP COLUMN dosis3;

COMMIT;

-- La queja resuelta (1): cuántas fórmulas llevan acetaminofén, con un solo filtro
SELECT m.nombre, count(*) AS formulas
FROM formula_medicamento fm JOIN medicamento m USING (id_medicamento)
WHERE m.nombre LIKE 'Acetaminof%'
GROUP BY m.nombre;

-- La queja resuelta (2): una fórmula con 4 medicamentos (de prueba, se deshace)
BEGIN;
INSERT INTO formula (num_formula, fecha, doc_paciente) VALUES (705, '2026-10-15', '1110000222');
INSERT INTO formula_medicamento (num_formula, id_medicamento, dosis)
SELECT 705, id_medicamento, 'cada 12 h' FROM medicamento
WHERE nombre IN ('Amoxicilina 500 mg', 'Ibuprofeno 400 mg', 'Omeprazol 20 mg', 'Loratadina 10 mg');
SELECT f.num_formula, p.nombre AS paciente, m.nombre AS medicamento, fm.dosis
FROM formula f
JOIN paciente p USING (doc_paciente)
JOIN formula_medicamento fm USING (num_formula)
JOIN medicamento m USING (id_medicamento)
WHERE f.num_formula = 705;
ROLLBACK;

-- PREGUNTA PROPIA: ¿por qué no basta con agregar medicamento4 y dosis4?
--   1. Solo corre el límite. Mañana llega una fórmula con 5 y se repite el
--      problema. Cada vez hay que hacer ALTER TABLE y cambiar todas las
--      consultas y pantallas que leen la tabla.
--   2. Cada consulta por medicamento necesita una condición por columna
--      (4 OR en la búsqueda, 4 UNION ALL para contar), y una consulta que se
--      quede con 3 da resultados incompletos sin avisar.
--   3. Más columnas en NULL: la mayoría de fórmulas tiene 1 o 2
--      medicamentos, así que la 3 y la 4 quedan vacías casi siempre.
--   4. La regla "un medicamento no se repite en la fórmula" sigue sin poder
--      declararse: habría que comparar las 4 columnas entre sí en un CHECK
--      (6 parejas), y tampoco se podría poner una FK a un catálogo de
--      medicamentos sin repetirla 4 veces.
--   Con la tabla formula_medicamento, una fórmula tiene tantas filas como
--   medicamentos, sin límite ni huecos, y la PK garantiza la regla.


-- #####################################################################
-- CASO 3: CURSOS LIBRES
-- inscripcion (id PK serial, doc_participante, nombre_participante, correo,
--              cod_curso, nombre_curso, cod_sede, direccion_sede, valor_pagado)
-- #####################################################################
\echo
\echo '=================== CASO 3: CURSOS LIBRES ==================='
SET search_path TO cursos_libres;

-- (a) DIAGNÓSTICO
--
-- Dependencias funcionales (con la regla del enunciado):
--   doc_participante -> nombre_participante, correo
--   correo -> doc_participante        (el correo identifica a un participante)
--   cod_curso -> nombre_curso, cod_sede  (cada curso se dicta en una sola sede)
--   cod_sede  -> direccion_sede
--   (doc_participante, cod_curso) -> valor_pagado, id
--                      (se inscribe a lo sumo una vez; el valor puede tener descuento)
--   id -> todo
--
-- Claves candidatas: id, (doc_participante, cod_curso) y (correo, cod_curso).
--
-- Problema principal (explica la queja): CLAVE SUSTITUTA SIN UNIQUE EN LA
-- CLAVE NATURAL.
--   Nada impide que (doc_participante, cod_curso) se repita, y Juliana Rey
--   quedó inscrita dos veces en Fotografía digital (filas 3 y 7, idénticas
--   salvo el id). La suma cuenta dos veces sus 200 000 pesos.
--
-- Problemas secundarios:
--   * NO ESTÁ EN 2FN: nombre_participante y correo dependen solo de
--     doc_participante, y nombre_curso y cod_sede solo de cod_curso. Son
--     dependencias de una PARTE de la clave candidata (doc_participante,
--     cod_curso). Que la PK declarada sea id no cambia eso.
--   * NO ESTÁ EN 3FN: cod_curso -> cod_sede -> direccion_sede es una
--     dependencia transitiva. La dirección de la sede S1 se repite en 5 filas.

-- (b) EVIDENCIA

-- La queja: Fotografía digital suma 580 000, pero en caja hay 380 000
SELECT nombre_curso, count(*) AS inscripciones, sum(valor_pagado) AS recaudo_segun_sistema
FROM inscripcion GROUP BY nombre_curso ORDER BY nombre_curso;

-- La causa: la clave natural (doc_participante, cod_curso) está repetida
SELECT doc_participante, cod_curso, count(*) AS veces, array_agg(id ORDER BY id) AS ids
FROM inscripcion
GROUP BY doc_participante, cod_curso
HAVING count(*) > 1;

-- Las dos filas son idénticas salvo el id: es un registro duplicado
SELECT * FROM inscripcion WHERE id IN (3, 7);

-- Las dependencias parciales y transitivas no tienen contradicciones (0 en todas)...
SELECT 'doc -> nombre, correo' AS dependencia, count(*) AS violaciones
FROM (SELECT doc_participante FROM inscripcion GROUP BY 1
      HAVING count(DISTINCT nombre_participante || '|' || correo) > 1) x
UNION ALL
SELECT 'correo -> doc', count(*)
FROM (SELECT correo FROM inscripcion GROUP BY 1
      HAVING count(DISTINCT doc_participante) > 1) x
UNION ALL
SELECT 'cod_curso -> nombre_curso, cod_sede', count(*)
FROM (SELECT cod_curso FROM inscripcion GROUP BY 1
      HAVING count(DISTINCT nombre_curso || '|' || cod_sede) > 1) x
UNION ALL
SELECT 'cod_sede -> direccion_sede', count(*)
FROM (SELECT cod_sede FROM inscripcion GROUP BY 1
      HAVING count(DISTINCT direccion_sede) > 1) x;

-- ...pero los datos se repiten (redundancia)
SELECT cod_sede, direccion_sede, count(*) AS veces
FROM inscripcion GROUP BY 1, 2 ORDER BY 3 DESC;
SELECT doc_participante, nombre_participante, count(*) AS veces
FROM inscripcion GROUP BY 1, 2 ORDER BY 3 DESC;

-- DECISIÓN sobre los datos: la fila 7 es un duplicado de la 3. Son iguales
-- en todo, incluido el valor, y la regla dice que un participante se
-- inscribe a lo sumo una vez por curso. Se conserva la de menor id (3) y se
-- descarta la 7. Contabilidad debe reversar los 200 000 cobrados de más (o
-- devolverlos a Juliana si de verdad pagó dos veces).

-- (c) ESQUEMA CORREGIDO
--   participante (doc_participante PK, nombre, correo UNIQUE)
--   sede         (cod_sede PK, direccion)
--   curso        (cod_curso PK, nombre, cod_sede FK -> sede)
--   inscripcion  (doc_participante FK -> participante, cod_curso FK -> curso,
--                 valor_pagado, PK (doc_participante, cod_curso))
--
-- Conteos esperados, calculados a mano ANTES de migrar:
--   participante: 4 (Juliana, Mateo, Valeria, Esteban)
--   sede: 2 (S1, S2)
--   curso: 3 (C10, C20, C30)
--   inscripcion: 8 filas - 1 duplicada = 7
--   recaudo de Fotografía digital: 200 000 + 180 000 = 380 000

-- (d) MIGRACIÓN
BEGIN;

ALTER TABLE inscripcion RENAME TO inscripcion_vieja;

CREATE TABLE participante (
    doc_participante  varchar(15)   PRIMARY KEY,
    nombre            varchar(80)   NOT NULL,
    correo            varchar(120)  NOT NULL UNIQUE
);
INSERT INTO participante (doc_participante, nombre, correo)
SELECT DISTINCT doc_participante, nombre_participante, correo FROM inscripcion_vieja;

CREATE TABLE sede (
    cod_sede   char(2)      PRIMARY KEY,
    direccion  varchar(60)  NOT NULL
);
INSERT INTO sede (cod_sede, direccion)
SELECT DISTINCT cod_sede, direccion_sede FROM inscripcion_vieja;

CREATE TABLE curso (
    cod_curso  char(3)      PRIMARY KEY,
    nombre     varchar(60)  NOT NULL,
    cod_sede   char(2)      NOT NULL REFERENCES sede (cod_sede)
);
INSERT INTO curso (cod_curso, nombre, cod_sede)
SELECT DISTINCT cod_curso, nombre_curso, cod_sede FROM inscripcion_vieja;

CREATE TABLE inscripcion (
    doc_participante  varchar(15)  NOT NULL REFERENCES participante (doc_participante),
    cod_curso         char(3)      NOT NULL REFERENCES curso (cod_curso),
    valor_pagado      integer      NOT NULL CHECK (valor_pagado >= 0),
    PRIMARY KEY (doc_participante, cod_curso)
);
-- DISTINCT ON deja una sola fila por (participante, curso): la de menor id
INSERT INTO inscripcion (doc_participante, cod_curso, valor_pagado)
SELECT DISTINCT ON (doc_participante, cod_curso)
       doc_participante, cod_curso, valor_pagado
FROM inscripcion_vieja
ORDER BY doc_participante, cod_curso, id;

-- (e) VERIFICACIÓN, antes de borrar lo viejo
SELECT 'participante' AS tabla, 4 AS esperado, count(*) AS obtenido FROM participante
UNION ALL SELECT 'sede',        2, count(*) FROM sede
UNION ALL SELECT 'curso',       3, count(*) FROM curso
UNION ALL SELECT 'inscripcion', 7, count(*) FROM inscripcion;

DO $$
BEGIN
    ASSERT (SELECT count(*) FROM participante) = 4, 'participante: se esperaban 4';
    ASSERT (SELECT count(*) FROM sede) = 2,         'sede: se esperaban 2';
    ASSERT (SELECT count(*) FROM curso) = 3,        'curso: se esperaban 3';
    ASSERT (SELECT count(*) FROM inscripcion) = 7,  'inscripcion: se esperaban 7';
END $$;

-- Lo viejo (sin el id, que es lo único que distingue al duplicado) EXCEPT
-- lo reconstruido con joins, y al revés: 0 filas cada una
SELECT doc_participante, nombre_participante, correo, cod_curso,
       nombre_curso, cod_sede, direccion_sede, valor_pagado
FROM inscripcion_vieja
EXCEPT
SELECT i.doc_participante, p.nombre, p.correo, i.cod_curso,
       c.nombre, c.cod_sede, s.direccion, i.valor_pagado
FROM inscripcion i
JOIN participante p USING (doc_participante)
JOIN curso c USING (cod_curso)
JOIN sede s USING (cod_sede);

SELECT i.doc_participante, p.nombre, p.correo, i.cod_curso,
       c.nombre, c.cod_sede, s.direccion, i.valor_pagado
FROM inscripcion i
JOIN participante p USING (doc_participante)
JOIN curso c USING (cod_curso)
JOIN sede s USING (cod_sede)
EXCEPT
SELECT doc_participante, nombre_participante, correo, cod_curso,
       nombre_curso, cod_sede, direccion_sede, valor_pagado
FROM inscripcion_vieja;

DROP TABLE inscripcion_vieja;

COMMIT;

-- La queja resuelta: Fotografía digital = 380 000
SELECT c.nombre AS curso, count(*) AS inscripciones, sum(i.valor_pagado) AS recaudo
FROM inscripcion i JOIN curso c USING (cod_curso)
GROUP BY c.nombre ORDER BY c.nombre;

-- Y ya no se puede repetir: la segunda inscripción de Juliana se rechaza
DO $$
BEGIN
    INSERT INTO cursos_libres.inscripcion VALUES ('1140000900', 'C20', 200000);
    RAISE NOTICE 'ERROR: se aceptó un duplicado';
EXCEPTION WHEN unique_violation THEN
    RAISE NOTICE 'Duplicado rechazado: %', SQLERRM;
END $$;

-- PREGUNTA PROPIA: la tabla tiene PK de una sola columna, ¿por qué eso no
-- la pone en 2FN? ¿Qué restricción faltaba y qué habría evitado?
--   La 2FN no habla solo de la PK declarada: exige que ningún atributo no
--   primo dependa de una parte de CUALQUIER clave candidata. Por las reglas
--   del negocio, (doc_participante, cod_curso) identifica una inscripción y
--   es clave candidata aunque nadie la haya declarado. nombre_participante y
--   correo dependen solo de doc_participante, y nombre_curso y cod_sede
--   solo de cod_curso: son dependencias parciales. El id solo cambió el
--   nombre de la PK, las dependencias siguen ahí ("agregar un id no
--   normaliza nada").
--
--   Faltaba UNIQUE (doc_participante, cod_curso). Con esa restricción, la
--   segunda inscripción de Juliana en C20 se habría rechazado al insertarla,
--   y Fotografía digital no habría sumado 200 000 pesos de más.


-- #####################################################################
-- CASO 4: ENVÍOS
-- envio (num_guia PK, fecha, ciudad_destino, departamento, zona,
--        tarifa_kg, peso_kg, valor)
-- #####################################################################
\echo
\echo '=================== CASO 4: ENVIOS ==================='
SET search_path TO envios;

-- (a) DIAGNÓSTICO
--
-- Dependencias funcionales:
--   num_guia       -> fecha, ciudad_destino, peso_kg (y todo lo demás)
--   ciudad_destino -> departamento, zona   (cada ciudad está en un depto y una zona)
--   zona           -> tarifa_kg            (cada zona tiene una tarifa por kilo)
--   peso_kg, tarifa_kg -> valor            (valor = peso * tarifa)
--
-- Problema principal (explica la queja): DATO DERIVADO GUARDADO.
--   valor se puede calcular con peso_kg * tarifa_kg, pero está guardado y
--   nada obliga a que coincida con el cálculo. En la guía G07 (Bogotá,
--   4 kg a 6 000) quedó 42 000 cuando debía ser 24 000: los dígitos están
--   invertidos. Al cliente se le cobraron 18 000 pesos de más.
--
-- Problemas secundarios: NO ESTÁ EN 3FN.
--   * num_guia -> ciudad_destino -> departamento, zona (transitiva)
--   * num_guia -> zona -> tarifa_kg (transitiva)
--   El departamento, la zona y la tarifa se repiten en cada envío, y se
--   podrían contradecir (por ejemplo, un envío a Cali en zona 2, u otro a
--   zona 1 con una tarifa distinta).
--   Además, en Colombia hay municipios con el mismo nombre en departamentos
--   distintos, así que el nombre solo no basta como clave de ciudad: se usa
--   (nombre, departamento).

-- (b) EVIDENCIA

-- La queja: el valor guardado no coincide con el cálculo
SELECT num_guia, ciudad_destino, peso_kg, tarifa_kg, valor,
       peso_kg * tarifa_kg AS valor_calculado,
       valor - peso_kg * tarifa_kg AS cobrado_de_mas
FROM envio
WHERE valor <> peso_kg * tarifa_kg;

-- Las dependencias transitivas no tienen contradicciones en los datos (0 y 0)...
SELECT ciudad_destino FROM envio GROUP BY 1
HAVING count(DISTINCT departamento || '|' || zona) > 1;
SELECT zona FROM envio GROUP BY 1 HAVING count(DISTINCT tarifa_kg) > 1;

-- ...pero se repiten en cada envío (redundancia)
SELECT ciudad_destino, departamento, zona, tarifa_kg, count(*) AS veces
FROM envio GROUP BY 1, 2, 3, 4 ORDER BY 5 DESC;

-- DECISIÓN sobre los datos: el valor correcto de G07 es 24 000 (4,0 kg x
-- 6 000). El peso y la tarifa de G07 coinciden con los de todos los demás
-- envíos de la zona 2, y 42 000 es 24 000 con los dígitos invertidos. El
-- error está en valor, no en el peso ni en la tarifa. Hay que devolverle
-- 18 000 pesos al cliente. Como valor deja de guardarse, la corrección
-- queda en la vista.

-- (c) ESQUEMA CORREGIDO (3FN)
--   zona   (zona PK, tarifa_kg)
--   ciudad (id_ciudad PK, nombre, departamento, zona FK -> zona,
--           UNIQUE (nombre, departamento))
--   envio  (num_guia PK, fecha, id_ciudad FK -> ciudad, peso_kg)
--   VIEW envio_valor: calcula valor = peso_kg * tarifa_kg, no se guarda
--   (pero ver la pregunta propia: al final se agrega tarifa_kg_aplicada)
--
-- Conteos esperados, calculados a mano ANTES de migrar:
--   zona: 3 (1, 2, 3)
--   ciudad: 5 (Cali, Palmira, Bogotá, Medellín, Pasto)
--   envio: 8, todos con ciudad
--   envíos cuyo valor guardado difiere del calculado: 1 (G07)

-- (d) MIGRACIÓN
BEGIN;

CREATE TEMP TABLE envio_original ON COMMIT DROP AS SELECT * FROM envio;

CREATE TABLE zona (
    zona       smallint  PRIMARY KEY,
    tarifa_kg  integer   NOT NULL CHECK (tarifa_kg > 0)
);
INSERT INTO zona (zona, tarifa_kg)
SELECT DISTINCT zona, tarifa_kg FROM envio;

CREATE TABLE ciudad (
    id_ciudad     integer      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nombre        varchar(40)  NOT NULL,
    departamento  varchar(40)  NOT NULL,
    zona          smallint     NOT NULL REFERENCES zona (zona),
    UNIQUE (nombre, departamento)
);
INSERT INTO ciudad (nombre, departamento, zona)
SELECT DISTINCT ciudad_destino, departamento, zona FROM envio ORDER BY 1;

ALTER TABLE envio ADD COLUMN id_ciudad integer;
UPDATE envio e
SET id_ciudad = c.id_ciudad
FROM ciudad c
WHERE c.nombre = e.ciudad_destino AND c.departamento = e.departamento;
ALTER TABLE envio
    ALTER COLUMN id_ciudad SET NOT NULL,
    ADD CONSTRAINT fk_envio_ciudad FOREIGN KEY (id_ciudad) REFERENCES ciudad (id_ciudad),
    ADD CONSTRAINT chk_peso CHECK (peso_kg > 0);

-- (e) VERIFICACIÓN, antes de borrar lo viejo
SELECT 'zona' AS tabla, 3 AS esperado, count(*) AS obtenido FROM zona
UNION ALL SELECT 'ciudad', 5, count(*) FROM ciudad
UNION ALL SELECT 'envio',  8, count(*) FROM envio;

DO $$
BEGIN
    ASSERT (SELECT count(*) FROM zona) = 3,   'zona: se esperaban 3';
    ASSERT (SELECT count(*) FROM ciudad) = 5, 'ciudad: se esperaban 5';
    ASSERT (SELECT count(*) FROM envio) = 8,  'envio: se esperaban 8';
END $$;

-- Lo viejo EXCEPT lo reconstruido con joins, y al revés (0 filas)
SELECT num_guia, fecha, ciudad_destino, departamento, zona, tarifa_kg, peso_kg
FROM envio_original
EXCEPT
SELECT e.num_guia, e.fecha, c.nombre, c.departamento, z.zona, z.tarifa_kg, e.peso_kg
FROM envio e JOIN ciudad c USING (id_ciudad) JOIN zona z ON z.zona = c.zona;

SELECT e.num_guia, e.fecha, c.nombre, c.departamento, z.zona, z.tarifa_kg, e.peso_kg
FROM envio e JOIN ciudad c USING (id_ciudad) JOIN zona z ON z.zona = c.zona
EXCEPT
SELECT num_guia, fecha, ciudad_destino, departamento, zona, tarifa_kg, peso_kg
FROM envio_original;

ALTER TABLE envio
    DROP COLUMN ciudad_destino,
    DROP COLUMN departamento,
    DROP COLUMN zona,
    DROP COLUMN tarifa_kg,
    DROP COLUMN valor;

-- El valor se calcula, no se guarda
CREATE VIEW envio_valor AS
SELECT e.num_guia, e.fecha, c.nombre AS ciudad, c.departamento, c.zona,
       z.tarifa_kg, e.peso_kg,
       round(e.peso_kg * z.tarifa_kg)::integer AS valor
FROM envio e
JOIN ciudad c USING (id_ciudad)
JOIN zona z ON z.zona = c.zona;

-- El valor viejo coincide con el calculado en todos los envíos salvo G07
SELECT o.num_guia, o.valor AS valor_guardado, v.valor AS valor_calculado
FROM envio_original o JOIN envio_valor v USING (num_guia)
WHERE o.valor <> v.valor;

DO $$
BEGIN
    ASSERT (SELECT count(*) FROM envio_original o JOIN envio_valor v USING (num_guia)
            WHERE o.valor <> v.valor) = 1, 'solo G07 debía diferir';
END $$;

COMMIT;

-- La queja resuelta: los envíos a Bogotá, con el valor bien calculado (G07 = 24 000)
SELECT num_guia, fecha, ciudad, peso_kg, tarifa_kg, valor
FROM envio_valor WHERE ciudad = 'Bogotá' ORDER BY num_guia;

-- PREGUNTA PROPIA: en enero suben las tarifas. Con el esquema corregido,
-- ¿qué pasa con el valor de los envíos de octubre?
--
-- Demostración: se sube la tarifa de la zona 2 y se deshace con ROLLBACK
BEGIN;
UPDATE zona SET tarifa_kg = 7000 WHERE zona = 2;
SELECT num_guia, fecha, ciudad, tarifa_kg, valor AS valor_octubre_recalculado
FROM envio_valor WHERE zona = 2 ORDER BY num_guia;   -- ¡cambiaron!
ROLLBACK;
--
--   El valor de un envío de octubre cambia solo, porque la vista lo
--   recalcula con la tarifa de HOY. Una factura ya cobrada no puede
--   cambiar: el cliente pagó con la tarifa vigente el día del envío.
--
--   ¿Por qué? Se supuso zona -> tarifa_kg para siempre, pero eso solo es
--   cierto en un momento dado. La tarifa con la que se cobró un envío es un
--   dato HISTÓRICO del envío: depende de num_guia (es la que regía en su
--   fecha), no de la zona actual. Que hoy coincida con la tarifa de la zona
--   no lo vuelve redundante. Es la misma diferencia que hay entre el precio
--   de lista de un producto y el precio que quedó en una factura.
--
--   Cambio propuesto: guardar en cada envío la tarifa aplicada
--   (num_guia -> tarifa_kg_aplicada). No es redundancia, porque no se puede
--   deducir de otros datos una vez cambia la tarifa de la zona. El valor sí
--   sigue siendo un dato DERIVADO (peso * tarifa_aplicada), así que no se
--   guarda: se calcula en la vista, y lo que pasó con G07 no se puede
--   repetir.
--   (Otra opción igual de válida: una tabla tarifa_zona (zona, vigente_desde,
--   tarifa_kg) y que la vista busque la tarifa vigente en la fecha del envío.)
--
-- Se aplica el cambio. Los datos originales de tarifa_kg coincidían con la
-- tarifa de su zona (evidencia de arriba: 0 contradicciones), así que
-- llenarla desde zona reproduce exactamente la tarifa histórica.
BEGIN;

ALTER TABLE envio ADD COLUMN tarifa_kg_aplicada integer;
UPDATE envio e
SET tarifa_kg_aplicada = z.tarifa_kg
FROM ciudad c JOIN zona z ON z.zona = c.zona
WHERE c.id_ciudad = e.id_ciudad;
ALTER TABLE envio
    ALTER COLUMN tarifa_kg_aplicada SET NOT NULL,
    ADD CONSTRAINT chk_tarifa_aplicada CHECK (tarifa_kg_aplicada > 0);

CREATE OR REPLACE VIEW envio_valor AS
SELECT e.num_guia, e.fecha, c.nombre AS ciudad, c.departamento, c.zona,
       e.tarifa_kg_aplicada AS tarifa_kg, e.peso_kg,
       round(e.peso_kg * e.tarifa_kg_aplicada)::integer AS valor
FROM envio e
JOIN ciudad c USING (id_ciudad);

COMMIT;

-- Mismo experimento que antes: ahora los envíos de octubre NO cambian
BEGIN;
UPDATE zona SET tarifa_kg = 7000 WHERE zona = 2;
SELECT num_guia, fecha, ciudad, tarifa_kg, valor AS valor_octubre
FROM envio_valor WHERE zona = 2 ORDER BY num_guia;   -- iguales: 6 000 por kilo
ROLLBACK;
-- (Para un envío nuevo, la aplicación o un DEFAULT/trigger, Hito 4, copia
-- en tarifa_kg_aplicada la tarifa vigente de la zona al momento de crearlo.)

\echo
\echo '=================== FIN ==================='
