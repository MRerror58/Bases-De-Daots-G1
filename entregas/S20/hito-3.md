# Hito 3: normalización del esquema `biblioteca`

**Grupo 1 · Proyecto Biblioteca**

| Integrante | Código |
|---|---|
| Santiago Ruiz Vanegas | 202177804 |
| Juan David Vasquez Cañas | 2515123 |
| Omar Esteban Agredo Titimbo | 2516317 |

Parte del examen de S19 ([`entregas/S19/parte-B.md`](../S19/parte-B.md)), cuya evidencia está en `entregas/S19/salida-parte-B.txt` (secciones B1 a B5). Los cambios se aplican con [`postgres/scripts/normalizacion.sql`](../../postgres/scripts/normalizacion.sql), y una base vacía queda creada ya normalizada con [`postgres/init/01_esquema.sql`](../../postgres/init/01_esquema.sql).

## 1. Esquema antes (S14 a S19)

- `usuario (id_usuario, nombre_usuario, contrasena_hash, rol, activo, fecha_creacion)`
- `lector (id_lector, id_usuario, documento, nombres, apellidos, correo, telefono, direccion, fecha_registro, activo)`
- `libro (isbn, titulo, autor, categoria, editorial, anio_publicacion, ejemplares_disponibles, activo)`
- `prestamo (id_prestamo, id_lector, isbn, registrado_por, devuelto_por, fecha_prestamo, fecha_vencimiento, fecha_devolucion)`
- Auxiliares de la carga: `rechazo_carga`, `stg_linea`, `stg_libro`, `stg_lector`.

Datos: 32 libros, 20 lectores, 20 usuarios, 0 préstamos.

## 2. Dependencias funcionales y claves candidatas

| Tabla | Dependencias (regla que las justifica) | Claves candidatas |
|---|---|---|
| usuario | `id_usuario → todo` (cada cuenta es una). `nombre_usuario → id_usuario` (el login identifica la cuenta). | `id_usuario`, `nombre_usuario` |
| lector | `id_lector → todo`. `documento → id_lector` (la cédula identifica a la persona). `correo → id_lector` (no hay dos lectores con el mismo correo, sin importar mayúsculas). `id_usuario → id_lector` (una cuenta por lector y un lector por cuenta). | `id_lector`, `documento`, `correo`, `id_usuario` |
| libro | `isbn → titulo, autor, categoria, editorial, anio_publicacion, activo` (el ISBN identifica la edición). `autor` y `categoria` no determinan nada: un autor tiene varios libros, en varias categorías. `ejemplares_disponibles` depende de `isbn` **y** de los préstamos abiertos: es un dato derivado. | `isbn` |
| prestamo | `id_prestamo → todo`. `(id_lector, isbn, fecha_prestamo) → todo` (un lector no saca el mismo libro dos veces el mismo día). `fecha_vencimiento` depende del préstamo, no de una regla: es el plazo vigente ese día (dato histórico, ver parte A, A5). El estado (activo, devuelto, vencido) se deduce de las fechas y no se guarda. | `id_prestamo`; la natural no estaba declarada |
| rechazo_carga, stg_* | `id → todo` en la bitácora. Las `stg_*` no imponen ninguna: son texto crudo del CSV. | `id`; las `stg_*` no tienen clave, por diseño |

## 3. Forma normal y problemas encontrados

| Tabla | Forma normal | Problema | Evidencia (S19, `salida-parte-B.txt`) |
|---|---|---|---|
| usuario | FNBC | Ninguno dentro de la tabla. `nombre_usuario` es igual a `lector.documento` en 20 de 20. | B1: `login_igual_a_documento = 20`. |
| lector | FNBC | Dos banderas `activo` sin significado escrito. `UNIQUE(correo)` distingue mayúsculas. | B2: con `ROLLBACK`, el lector 1 queda con `lector.activo = t` y `usuario.activo = f`, y se acepta. |
| libro | FNBC formal, **1FN en riesgo** | `autor` es un solo texto: varios autores obligan a una lista en la celda. `categoria` y `autor` se repiten como texto (Novela 14 veces, García Márquez 3). `ejemplares_disponibles` es derivado y nada lo actualiza. | B3: el libro de prueba queda con `'Silberschatz, Korth, Sudarshan'` en una celda; con 3 préstamos abiertos del libro 9780000000003, `ejemplares_disponibles` sigue en 2. |
| prestamo | 3FN respecto a `id_prestamo` | Préstamos duplicados aceptados; `devuelto_por` sin `fecha_devolucion` aceptado; el préstamo es de un ISBN, no de una copia física. | B4: dos inserciones iguales dan `veces = 2`; la devolución a medias se acepta. |
| rechazo_carga, stg_* | FNBC / no aplica | Ninguno. | B5. |

## 4. Cambios aplicados y migración

| Cambio | Por qué |
|---|---|
| `categoria (id_categoria, nombre UNIQUE)` y `libro.id_categoria` FK | Cada categoría se escribe una vez; una variante mal escrita ya no crea otra categoría. |
| `autor (id_autor, nombre UNIQUE)` y `libro_autor (isbn, id_autor)` | Varios autores por libro sin listas en una celda (1FN). La búsqueda por autor es una igualdad. |
| `editorial (id_editorial, nombre UNIQUE)` y `libro.id_editorial` FK, opcional | Hoy ningún libro tiene editorial; cuando se llene, no se repetirá como texto. |
| `ejemplar (id_ejemplar, isbn, activo)`; `prestamo.id_ejemplar` reemplaza a `prestamo.isbn` | Se sabe qué copia tiene cada lector, y los disponibles se cuentan. Se quita `libro.ejemplares_disponibles`. |
| `UNIQUE (id_lector, id_ejemplar, fecha_prestamo)` | Declara la clave natural del préstamo. |
| Índice único parcial `prestamo (id_ejemplar) WHERE fecha_devolucion IS NULL` | Una copia no puede estar prestada dos veces a la vez. Es además el índice que usa el cálculo de disponibles. |
| `CHECK ((devuelto_por IS NULL) = (fecha_devolucion IS NULL))` | La devolución se registra completa o no se registra. |
| Índice único sobre `lower(lector.correo)` en lugar de `UNIQUE(correo)` | `Ana@x.com` y `ana@x.com` son el mismo correo. La carga de lectores compara también con `lower()`. |
| `COMMENT` en `usuario.activo` (puede iniciar sesión), `lector.activo` (puede pedir préstamos) y `usuario.nombre_usuario` | Las dos banderas miden cosas distintas y se quedan. El login es un dato de la cuenta, independiente del documento: no es una copia que deba sincronizarse, y se queda. |

**Cómo se migró.** `normalizacion.sql` sigue la receta de S19: imprime la evidencia, abre `BEGIN`, crea las tablas nuevas, copia los datos, verifica y solo entonces borra las columnas viejas y hace `COMMIT`. Si ya se corrió, se detiene sin tocar nada. Cada libro recibe tantos ejemplares como su `ejemplares_disponibles`, que nunca se descontó al prestar (S19, B3) y por eso es el número de copias que llegó en la carga. Los préstamos abiertos de un ISBN se reparten entre copias distintas; los devueltos van a la primera copia, porque el esquema viejo no guardaba cuál salió.

| Conteo (`salida-normalizacion.txt`) | Antes | Después |
|---|---|---|
| Libros | 32 | 32 |
| Ejemplares | 94 (suma de `ejemplares_disponibles`) | 94 filas en `ejemplar` |
| Categorías / autores / editoriales | texto en `libro` | 9 / 29 / 0 filas |
| Filas de `libro_autor` | | 32 |
| Préstamos | 0 | 0 |
| `EXCEPT` libro antes contra `libro_detalle`, en los dos sentidos | | 0 filas |

La base del grupo no tiene préstamos, así que la migración se probó también sobre una copia con los 15 préstamos de prueba de S16 confirmados (`salida-prueba-migracion.txt`): 15 antes y 15 después, 0 filas en el `EXCEPT` de préstamos, y los seis abiertos quedan en copias distintas.

## 5. Desnormalizaciones deliberadas: ninguna

| Dato | Decisión | Justificación |
|---|---|---|
| Ejemplares disponibles | **Se calcula** en la vista `libro_disponibilidad` (ejemplares activos menos préstamos abiertos). | En la parte A, con 15 000 ejemplares y 303 750 préstamos, el índice parcial bajó el catálogo de ~27 ms a ~3,7 ms sin ninguna copia; la columna guardada llegaba a ~1 ms, pero se desincronizó con un solo `INSERT` (A3 c). En el proyecto, con 94 ejemplares, la vista tarda ~0,3 ms. Guardar la columna exigiría un trigger y una consulta de verificación para ganar algo que no se nota. |
| Estado del préstamo | **Se calcula** en la vista `prestamo_estado`. | Depende de las fechas y de `CURRENT_DATE`: un préstamo pasa de activo a vencido sin que nadie escriba nada. Una columna guardada estaría mal cada medianoche. |
| Top de libros más prestados | **Consulta directa** (reporte 1). | La vista materializada solo se justifica con volumen (parte A, A4: ~355 ms contra ~0,02 ms con 303 750 préstamos). Si el volumen crece, se crea `top_prestados` y se refresca una vez al día. |
| `fecha_vencimiento` | **Se guarda**, y no es desnormalización. | Es un dato histórico del préstamo: el plazo vigente ese día (parte A, A5). |

Si en el futuro se decide guardar los disponibles, el mecanismo sería un trigger sobre `prestamo` (Hito 4) y la verificación sería la vista `descuadre` de `parte-A.sql`, adaptada a `libro_disponibilidad`.

**Pendiente para el Hito 4 (triggers):** validar que `registrado_por` y `devuelto_por` tengan rol de bibliotecario, y que un lector no tenga dos préstamos abiertos del mismo libro en copias distintas. Las dos reglas miran otra tabla, y un `CHECK` no puede hacerlo.

## 6. Esquema después

Todas las tablas del modelo quedan en **FNBC**: en cada una, todo determinante es una clave candidata declarada (PK o `UNIQUE`). Ninguna queda en 3FN sin FNBC.

| Tabla | Claves | Determinantes |
|---|---|---|
| `usuario` | `id_usuario`, `nombre_usuario` | los dos son clave |
| `lector` | `id_lector`, `documento`, `lower(correo)`, `id_usuario` | los cuatro son clave |
| `categoria`, `autor`, `editorial` | `id_*`, `nombre` | los dos son clave |
| `libro (isbn, titulo, id_categoria, id_editorial, anio_publicacion, activo)` | `isbn` | solo `isbn` |
| `libro_autor (isbn, id_autor)` | `(isbn, id_autor)` | toda la tabla es la clave |
| `ejemplar (id_ejemplar, isbn, activo)` | `id_ejemplar` | solo `id_ejemplar` |
| `prestamo (id_prestamo, id_lector, id_ejemplar, registrado_por, devuelto_por, fecha_prestamo, fecha_vencimiento, fecha_devolucion)` | `id_prestamo`, `(id_lector, id_ejemplar, fecha_prestamo)` | los dos son clave |

Vistas de lo derivado: `libro_disponibilidad`, `libro_detalle` (el libro con sus autores y su categoría en una fila) y `prestamo_estado`. Las auxiliares de la carga no cambian.

**Cómo se comprobó:**

- `postgres/init/01_esquema.sql` corre limpio en una base vacía, y las cuatro cargas de S14 más el CSV propio dan los mismos cargados y los mismos motivos de rechazo que en S14 (`salida-init-y-cargas.txt`).
- Las columnas, restricciones, índices, vistas y comentarios de la base migrada y de la base creada desde `init/` son idénticos (comparación de `information_schema` y `pg_catalog`).
- Los cuatro reportes de S16 (`reportes.sql`, con los joins ajustados a `ejemplar` y `libro_autor`) dan los mismos resultados que en el Hito 2 (`salida-reportes.txt`). Las fechas de vencimiento salen un día después porque se corrió el 22 de noviembre y no el 21; los días de mora son los mismos.
- `pruebas-restricciones.sql` repite lo que el esquema de S19 aceptaba, y ahora cada caso lo rechaza una restricción con nombre: `uq_prestamo_natural`, `prestamo_abierto_key`, `chk_devolucion_completa`, `lector_correo_lower_key` y `fk_libro_categoria` (`salida-pruebas-restricciones.txt`).
