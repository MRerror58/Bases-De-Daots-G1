# S22 parte A: respuestas

## A1 (b) Acciones `ON DELETE`

| FK | Acción | Justificación |
|---|---|---|
| `sala_recurso → sala` | `CASCADE` | El recurso no existe sin su sala: al borrar la Sala D desaparecen sus recursos (la consulta devuelve 0). |
| `reserva → sala` | `RESTRICT` | La reserva es historial: una sala con reservas no se puede borrar (el `DELETE` de la sala 1 falla). |
| `reserva → estudiante` | `RESTRICT` | Mismo criterio: borrar al estudiante no puede borrar el registro de lo que reservó. |

## A1 (d) Qué reglas viola el último `INSERT`

Viola la regla 2 (9 asistentes en una sala de capacidad 4) y la regla 3 (se cruza con las reservas de Ana y Bruno en la sala 1).

Ningún `CHECK` puede impedirlo porque un `CHECK` solo ve la fila que se inserta. La capacidad está en otra tabla, y el cruce depende de las demás filas de `reserva`. Son reglas entre filas y entre tablas, y por eso van en un trigger.

## A4 (b) Por qué `p_excluir`

Sin `p_excluir`, la propia reserva aparecería entre las activas que se cruzan con el intervalo nuevo. `sala_libre` devolvería falso siempre y cualquier `UPDATE` de una reserva activa fallaría con "sala ocupada", incluso uno que solo cambia `asistentes`.

## A4 (d) Reglas 4 y 5 en el trigger o solo en el procedimiento

Solo en el procedimiento. Las reglas 2 y 3 son invariantes físicas (capacidad y doble reserva) y deben valer para cualquiera que escriba en la tabla. Las reglas 4 y 5 son política de uso y admiten excepciones legítimas: la coordinación reserva la sala C para un evento a nombre de un monitor, que no es un estudiante con cupo semanal, y una sanción no debería impedir esa reserva. Si esas reglas vivieran en el trigger, ese caso no tendría salida sin desactivarlo.

El ejemplo de las 4 horas además choca con `reserva_duracion`: una regla de política metida en un `CHECK` tampoco admite la excepción. El procedimiento es el camino del caso de uso; el costo es que un `INSERT` directo se salta las reglas 4 y 5, y eso es aceptable porque son política, no integridad.

## A5 Por qué Bruno no queda sancionado

El último `UPDATE` no toca la columna `estado`, y el trigger es `AFTER UPDATE OF estado`: no se dispara. Aunque se disparara, el `WHEN` exige el paso a `no_asistio` desde otro estado, y Bruno ya estaba en `no_asistio`.

Sin el `WHEN`, cualquier `UPDATE` que dejara la fila en `no_asistio` volvería a poner la sanción en `hoy + 7`. Cada corrección posterior de esa reserva alargaría la sanción, y el estudiante nunca saldría de ella.

## A6 (b) Ciclo contra conjunto

| Versión | Sentencias `UPDATE` | Disparos de `reserva_validar` |
|---|---|---|
| `cerrar_vencidas_ciclo()` | 2 000, una por fila | 2 000 |
| `cerrar_vencidas()` | 1 | 2 000 |

La sentencia única no reduce los disparos del trigger, porque es `FOR EACH ROW`. Lo que ahorra es el número de sentencias, sus planes y los viajes al servidor. Con 2 000 filas la diferencia es de escala; el trigger sigue pagando una ejecución por fila.
