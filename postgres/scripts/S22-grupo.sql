-- S22. Parte A: reservas de salas de estudio.
-- Se corre despues de S22-reservas.sql (el script base del LMS):
--   psql -U curso -d curso -f /scripts/S22-reservas.sql
--   psql -U curso -d curso -f /scripts/S22-grupo.sql
--
-- Los nombres ..._fkey son los que PostgreSQL asigna a las FK declaradas sin
-- nombre en el script base. Si alla tienen otro nombre, se ajustan aqui.

SET search_path TO reservas;


-- A1. Restricciones y acciones referenciales

ALTER TABLE reserva
    ADD CONSTRAINT reserva_orden      CHECK (fin > inicio),
    ADD CONSTRAINT reserva_duracion   CHECK (fin - inicio <= interval '3 hours'),
    ADD CONSTRAINT reserva_horario    CHECK (inicio::date = fin::date
                                             AND inicio::time >= time '07:00'
                                             AND fin::time <= time '21:00'),
    ADD CONSTRAINT reserva_asistentes CHECK (asistentes > 0);

-- El recurso pertenece a la sala: si la sala se borra, sus recursos se van con ella.
ALTER TABLE sala_recurso
    DROP CONSTRAINT sala_recurso_id_sala_fkey,
    ADD CONSTRAINT sala_recurso_sala_fk FOREIGN KEY (id_sala)
        REFERENCES sala (id_sala) ON DELETE CASCADE;

-- Las reservas son historial: una sala con reservas no se puede borrar.
ALTER TABLE reserva
    DROP CONSTRAINT reserva_id_sala_fkey,
    ADD CONSTRAINT reserva_sala_fk FOREIGN KEY (id_sala)
        REFERENCES sala (id_sala) ON DELETE RESTRICT;

-- Mismo criterio: el historial de quien reservo no desaparece con el estudiante.
ALTER TABLE reserva
    DROP CONSTRAINT reserva_codigo_fkey,
    ADD CONSTRAINT reserva_estudiante_fk FOREIGN KEY (codigo)
        REFERENCES estudiante (codigo) ON DELETE RESTRICT;

-- Bateria de A1(c). Cada INSERT debe fallar por su restriccion.
INSERT INTO reserva (id_sala, codigo, inicio, fin, asistentes)
VALUES (1, '2610006', dia(4) + time '10:00', dia(4) + time '09:00', 2);   -- falla: reserva_orden
INSERT INTO reserva (id_sala, codigo, inicio, fin, asistentes)
VALUES (1, '2610006', dia(4) + time '08:00', dia(4) + time '12:00', 2);   -- falla: reserva_duracion
INSERT INTO reserva (id_sala, codigo, inicio, fin, asistentes)
VALUES (1, '2610006', dia(4) + time '20:00', dia(4) + time '22:00', 2);   -- falla: reserva_horario
INSERT INTO reserva (id_sala, codigo, inicio, fin, asistentes)
VALUES (1, '2610006', dia(4) + time '10:00', dia(4) + time '11:00', 0);   -- falla: reserva_asistentes

-- La sala 4 no tiene reservas: se borra y se lleva sus recursos (CASCADE).
BEGIN;
DELETE FROM sala WHERE id_sala = 4;
SELECT count(*) AS recursos_que_quedan FROM sala_recurso WHERE id_sala = 4;
ROLLBACK;

-- La sala 1 tiene reservas: el DELETE falla por RESTRICT.
DELETE FROM sala WHERE id_sala = 1;

-- Pasa todos los CHECK y aun asi viola las reglas 2 y 3 (capacidad y cruce).
BEGIN;
INSERT INTO reserva (id_sala, codigo, inicio, fin, asistentes)
VALUES (1, '2610006', dia(1) + time '09:00', dia(1) + time '10:00', 9);
ROLLBACK;


-- A2. Funciones de apoyo

-- Horas reservadas por el estudiante en la semana del dia dado. Las canceladas no cuentan.
CREATE OR REPLACE FUNCTION horas_semana(p_codigo varchar, p_dia date)
RETURNS numeric
LANGUAGE sql STABLE
AS $$
    SELECT coalesce(round(sum(extract(epoch FROM (fin - inicio)) / 3600), 1), 0)::numeric(10,1)
    FROM reserva
    WHERE codigo = p_codigo
      AND estado <> 'cancelada'
      AND date_trunc('week', inicio) = date_trunc('week', p_dia::timestamp);
$$;

-- Verdadero si la sala no tiene ninguna reserva activa que se cruce con [p_inicio, p_fin).
-- p_excluir deja fuera una reserva, para que un UPDATE no choque consigo mismo.
CREATE OR REPLACE FUNCTION sala_libre(
    p_sala    integer,
    p_inicio  timestamp,
    p_fin     timestamp,
    p_excluir integer DEFAULT NULL
)
RETURNS boolean
LANGUAGE sql STABLE
AS $$
    SELECT NOT EXISTS (
        SELECT 1
        FROM reserva
        WHERE id_sala = p_sala
          AND estado = 'activa'
          AND (p_excluir IS NULL OR id <> p_excluir)
          AND inicio < p_fin
          AND p_inicio < fin
    );
$$;

SELECT codigo, horas_semana(codigo, dia(1))   AS proxima,
               horas_semana(codigo, dia(-13)) AS pasada
FROM   estudiante ORDER BY codigo;
-- proxima: Ana 5.0, Bruno 2.0, Carla 3.0, Diego 2.0, Elena 0.0, Felipe 0.0
-- pasada:  Bruno 2.0, Carla 2.0, Felipe 2.0, los demas 0.0

SELECT sala_libre(1, dia(1) + time '09:00', dia(1) + time '11:00')    AS a,   -- f
       sala_libre(1, dia(1) + time '12:00', dia(1) + time '14:00')    AS b,   -- t
       sala_libre(2, dia(3) + time '08:00', dia(3) + time '10:00')    AS c,   -- t
       sala_libre(1, dia(1) + time '08:00', dia(1) + time '10:00', 1) AS d;   -- t


-- A3. Procedimientos

-- Regla 5 (sancion), regla 2 (capacidad y mantenimiento), regla 3 (cruce), regla 4 (6 horas).
CREATE OR REPLACE PROCEDURE reservar(
    p_codigo     varchar,
    p_sala       integer,
    p_inicio     timestamp,
    p_fin        timestamp,
    p_asistentes integer
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_sancion   date;
    v_capacidad integer;
    v_activa    boolean;
    v_horas     numeric;
    v_id        integer;
BEGIN
    SELECT sancionado_hasta INTO v_sancion FROM estudiante WHERE codigo = p_codigo;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El estudiante % no existe', p_codigo;
    END IF;
    IF v_sancion >= CURRENT_DATE THEN
        RAISE EXCEPTION 'El estudiante % esta sancionado hasta %', p_codigo, v_sancion;
    END IF;

    SELECT capacidad, activa INTO v_capacidad, v_activa FROM sala WHERE id_sala = p_sala;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'La sala % no existe', p_sala;
    END IF;
    IF NOT v_activa THEN
        RAISE EXCEPTION 'La sala % esta en mantenimiento', p_sala;
    END IF;
    IF p_asistentes > v_capacidad THEN
        RAISE EXCEPTION 'La sala % admite % personas, no %', p_sala, v_capacidad, p_asistentes;
    END IF;

    IF NOT sala_libre(p_sala, p_inicio, p_fin) THEN
        RAISE EXCEPTION 'La sala % esta ocupada en ese horario', p_sala;
    END IF;

    v_horas := horas_semana(p_codigo, p_inicio::date)
               + extract(epoch FROM (p_fin - p_inicio)) / 3600;
    IF v_horas > 6 THEN
        RAISE EXCEPTION 'El estudiante % superaria las 6 horas semanales (lleva % h)',
            p_codigo, horas_semana(p_codigo, p_inicio::date);
    END IF;

    INSERT INTO reserva (id_sala, codigo, inicio, fin, asistentes)
    VALUES (p_sala, p_codigo, p_inicio, p_fin, p_asistentes)
    RETURNING id INTO v_id;
    RAISE NOTICE 'Reserva % creada', v_id;
END;
$$;

-- Regla 6: solo se cancela una reserva activa que aun no ha empezado.
CREATE OR REPLACE PROCEDURE cancelar(p_id integer)
LANGUAGE plpgsql
AS $$
DECLARE
    v_estado varchar;
    v_inicio timestamp;
BEGIN
    SELECT estado, inicio INTO v_estado, v_inicio FROM reserva WHERE id = p_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'La reserva % no existe', p_id;
    END IF;
    IF v_estado <> 'activa' THEN
        RAISE EXCEPTION 'La reserva % no esta activa (estado: %)', p_id, v_estado;
    END IF;
    IF v_inicio <= now() THEN
        RAISE EXCEPTION 'La reserva % ya empezo y no se puede cancelar', p_id;
    END IF;

    UPDATE reserva SET estado = 'cancelada' WHERE id = p_id;
    RAISE NOTICE 'Reserva % cancelada', p_id;
END;
$$;

-- Bateria de A3(c).
CALL reservar('2610005', 1, dia(4) + time '08:00', dia(4) + time '10:00', 2);   -- 1  error: sancionada
CALL reservar('2610006', 4, dia(4) + time '08:00', dia(4) + time '10:00', 2);   -- 2  error: mantenimiento
CALL reservar('2610006', 1, dia(4) + time '08:00', dia(4) + time '10:00', 5);   -- 3  error: capacidad 4
CALL reservar('2610006', 1, dia(1) + time '09:00', dia(1) + time '11:00', 2);   -- 4  error: sala ocupada
CALL reservar('2610001', 2, dia(4) + time '08:00', dia(4) + time '10:00', 3);   -- 5  error: pasaria de 6 h
CALL reservar('2610006', 1, dia(1) + time '12:00', dia(1) + time '14:00', 3);   -- 6  reserva creada
CALL reservar('2610004', 2, dia(3) + time '08:00', dia(3) + time '10:00', 4);   -- 7  reserva creada
CALL reservar('2610001', 2, dia(4) + time '08:00', dia(4) + time '09:00', 3);   -- 8  reserva creada (6 h justas)
CALL reservar('2610099', 2, dia(4) + time '08:00', dia(4) + time '09:00', 3);   -- 9  error: no existe
CALL cancelar(7);                                                               -- 10 error: no esta activa
CALL cancelar(2);                                                               -- 11 cancela la de Bruno


-- A4. Trigger de validacion (reglas 2 y 3 para toda reserva activa)

-- Antes del trigger, esto pasa: 12 personas en una sala de 10, encima de la reserva de Ana.
BEGIN;
INSERT INTO reserva (id_sala, codigo, inicio, fin, asistentes)
VALUES (3, '2610005', dia(2) + time '10:00', dia(2) + time '11:00', 12);
ROLLBACK;

CREATE OR REPLACE FUNCTION validar_reserva() RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_capacidad integer;
    v_activa    boolean;
BEGIN
    IF NEW.estado <> 'activa' THEN
        RETURN NEW;
    END IF;

    SELECT capacidad, activa INTO v_capacidad, v_activa FROM sala WHERE id_sala = NEW.id_sala;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'La sala % no existe', NEW.id_sala;
    END IF;
    IF NOT v_activa THEN
        RAISE EXCEPTION 'La sala % esta en mantenimiento', NEW.id_sala;
    END IF;
    IF NEW.asistentes > v_capacidad THEN
        RAISE EXCEPTION 'La sala % admite % personas, no %', NEW.id_sala, v_capacidad, NEW.asistentes;
    END IF;

    -- NEW.id excluye la propia fila; sin el, todo UPDATE chocaria consigo mismo.
    IF NOT sala_libre(NEW.id_sala, NEW.inicio, NEW.fin, NEW.id) THEN
        RAISE EXCEPTION 'La sala % esta ocupada en ese horario', NEW.id_sala;
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS reserva_validar ON reserva;
CREATE TRIGGER reserva_validar
    BEFORE INSERT OR UPDATE ON reserva
    FOR EACH ROW EXECUTE FUNCTION validar_reserva();

-- Bateria de A4(c).
INSERT INTO reserva (id_sala, codigo, inicio, fin, asistentes)
VALUES (3, '2610005', dia(2) + time '10:00', dia(2) + time '11:00', 12);   -- falla: capacidad
INSERT INTO reserva (id_sala, codigo, inicio, fin, asistentes)
VALUES (3, '2610005', dia(2) + time '10:00', dia(2) + time '11:00', 6);    -- falla: sala ocupada
UPDATE reserva SET inicio = dia(3) + time '09:00' WHERE id = 6;            -- falla: choca con Diego 8:00
UPDATE reserva SET asistentes = 5 WHERE id = 6;                            -- pasa
UPDATE reserva SET estado = 'activa' WHERE id = 5;                         -- falla: reactivarla la cruza


-- A5. Trigger que reacciona al cambio de estado

-- Pasar una reserva a no_asistio sanciona al estudiante por 7 dias.
CREATE OR REPLACE FUNCTION sancionar_inasistencia() RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE estudiante
    SET sancionado_hasta = CURRENT_DATE + 7
    WHERE codigo = NEW.codigo;
    RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS reserva_sancionar ON reserva;
CREATE TRIGGER reserva_sancionar
    AFTER UPDATE OF estado ON reserva
    FOR EACH ROW
    WHEN (NEW.estado = 'no_asistio' AND OLD.estado <> 'no_asistio')
    EXECUTE FUNCTION sancionar_inasistencia();

UPDATE reserva SET estado = 'no_asistio' WHERE id = 7;    -- Felipe no se presento
SELECT codigo, nombre, sancionado_hasta - CURRENT_DATE AS dias
FROM   estudiante WHERE sancionado_hasta IS NOT NULL;     -- Elena 30, Felipe 7
CALL reservar('2610006', 3, dia(5) + time '08:00', dia(5) + time '10:00', 2);   -- falla: Felipe sancionado
UPDATE reserva SET asistentes = 2 WHERE id = 8;           -- no cambia estado: Bruno no queda sancionado


-- A6. Ciclo reescrito como una sola sentencia

CREATE OR REPLACE PROCEDURE cerrar_vencidas()
LANGUAGE sql
AS $$
    UPDATE reserva
    SET estado = 'cumplida'
    WHERE estado = 'activa' AND fin < now();
$$;

CALL cerrar_vencidas();
