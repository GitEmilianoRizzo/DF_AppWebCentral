import { Boxes } from 'lucide-react'
import { SeccionEnConstruccion } from '@/components/layout/SeccionEnConstruccion'

export function Stock() {
  return (
    <SeccionEnConstruccion
      titulo="Stock"
      icono={Boxes}
      descripcion="Existencias y movimientos: stock por deposito, rotacion, faltantes y diferencias de inventario."
      pendientes={[
        'Definir el alcance de la seccion',
        'Identificar de donde salen los datos de stock',
      ]}
    />
  )
}
