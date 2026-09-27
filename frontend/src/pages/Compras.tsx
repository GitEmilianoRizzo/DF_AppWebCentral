import { ShoppingCart } from 'lucide-react'
import { SeccionEnConstruccion } from '@/components/layout/SeccionEnConstruccion'

export function Compras() {
  return (
    <SeccionEnConstruccion
      titulo="Compras"
      icono={ShoppingCart}
      descripcion="Compras y abastecimiento: proveedores, ordenes, costos de reposicion y evolucion de precios."
      pendientes={[
        'Definir el alcance de la seccion',
        'Identificar de donde salen los datos de compras',
      ]}
    />
  )
}
